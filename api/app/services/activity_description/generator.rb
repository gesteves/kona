module ActivityDescription
  # Composes a Strava-ready description for an Intervals.icu activity — and tidies its name —
  # then PUTs both back, orchestrating the data gathering, the two Anthropic-backed lines, and
  # Composer's pure block builders.
  class Generator
    # Prefix shared by every log line this generator emits, for greppability.
    LOG_PREFIX = "Description:"

    # Activity types eligible for a generated description — swim/bike/run only.
    ELIGIBLE_SPORTS = %w[Cycling Running Swimming].freeze

    # Sports eligible for the LLM planned-workout headline (🗓️ line).
    HEADLINE_SPORTS = %w[Cycling Running].freeze

    # Dedupes rapid duplicate triggers for one activity, which would otherwise spend double
    # the LLM tokens and race the final PUT. The TTL bounds a crashed worker's hold.
    LOCK_TTL = 10.minutes

    def initialize(intervals: Intervals.new, trainer_road: nil)
      @intervals = intervals
      @trainer_road = trainer_road
    end

    # Generates and writes the description for an activity.
    # @param activity_id [String, Integer] The Intervals.icu activity id.
    # @param whoop_strain [Float, nil] Optional Whoop strain for the 🔥 line, or nil — the
    #   description is then composed without it (e.g. when triggered by a non-Whoop source).
    def generate!(activity_id, whoop_strain: nil)
      with_dedup_lock(activity_id) do
        run(activity_id, whoop_strain)
      end
    end

    private

    def run(activity_id, whoop_strain)
      activity = @intervals.activity!(activity_id)
      sport = ActivityMatcher.normalize_type(activity[:type])

      unless ELIGIBLE_SPORTS.include?(sport)
        log_info("activity #{activity_id} is not swim/bike/run (type=#{activity[:type] || 'unknown'}) — skipping")
        return
      end
      if activity[:pool_length].present?
        log_info("activity #{activity_id} is a pool swim — skipping")
        return
      end

      swim = sport == "Swimming"
      description = Composer.compose(
        headline: Composer.headline(activity[:description]),
        planned: planned_summary_line(activity, sport),
        weather: weather_line(activity),
        water_temp: water_temp_line(activity, swim),
        power: Composer.power_block(activity),
        heat: heat_line(activity, swim),
        whoop: Composer.whoop_block(whoop_strain, swim: swim)
      )

      name = Composer.clean_name(activity[:name])

      fields = {}
      fields[:name] = name if name.present? && name != activity[:name]
      fields[:description] = description if description.present?

      if fields.empty?
        log_info("activity #{activity_id}: nothing to write — skipping")
        return
      end

      @intervals.update_activity!(activity_id, **fields)
      log_info("activity #{activity_id}: updated #{fields.keys.join(', ')}")
    end

    # The 🗓️ planned-workout summary: the one TrainerRoad workout whose name appears verbatim
    # and case-sensitively in the activity's name, summarized by the LLM. Zero or ambiguous
    # matches mean no headline. Cycling and running only.
    # @return [String, nil]
    def planned_summary_line(activity, sport)
      return unless HEADLINE_SPORTS.include?(sport)
      return if activity[:name].blank?

      planned = planned_workouts_for(activity)
      matches = planned.select do |workout|
        workout[:sport].present? &&
          ActivityMatcher.compatible_types?(sport, workout[:sport]) &&
          workout[:name].present? &&
          activity[:name].include?(workout[:name])
      end

      if matches.empty?
        log_info("no TR planned workout name appears in activity name #{activity[:name].inspect} — no headline")
        return
      end
      if matches.size > 1
        log_warn("ambiguous TR name match for activity #{activity[:name].inspect}: #{matches.map { |m| m[:name] }.join(', ')} — refusing to pick, skipping headline")
        return
      end

      description = matches.first[:description]
      return if description.blank?

      swallow("planned summary") { Llm.planned_summary(description) }
    end

    # @return [Array<Hash>] The planned workouts for the activity's local date; empty when no
    #   feed is configured or the fetch fails, so a broken calendar loses only this line.
    def planned_workouts_for(activity)
      swallow("TrainerRoad planned workouts", fallback: []) do
        date = activity_date(activity)
        next [] if date.nil?

        trainer_road = @trainer_road || TrainerRoad.new(@intervals.athlete_timezone)
        trainer_road.planned_workouts(date) || []
      end
    end

    # The LLM weather sentence ("{emoji} {sentence}"). Indoor activities never get one.
    # @return [String, nil]
    def weather_line(activity)
      return if indoor?(activity)

      text = @intervals.activity_weather_summary(activity[:id])
      return if text.blank?

      result = swallow("weather sentence") { Llm.weather_sentence(text) }
      return if result.nil?

      "#{result[:emoji]} #{result[:sentence]}"
    end

    # The 💧 water-temperature line (open-water swims only), from the activity's temp stream.
    # @return [String, nil]
    def water_temp_line(activity, swim)
      return unless swim
      return unless activity[:stream_types]&.include?("temp")

      samples = stream_data(activity[:id], "temp")
      return if samples.blank?

      Composer.water_temp_block(median(samples), unit: @intervals.temperature_unit)
    end

    # The 🌡️ heat line: max and median heat strain index, plus the day's heat-adaptation score.
    # @return [String, nil]
    def heat_line(activity, swim)
      return if swim

      max_hsi, median_hsi = heat_strain_values(activity)

      date = activity_date(activity)
      score = date && @intervals.wellness(date)&.dig(:CoreHeatAdaptationScore)
      score = nil unless score.is_a?(Numeric)

      Composer.heat_block(max_hsi: max_hsi, median_hsi: median_hsi, heat_adaptation_score: score, swim: swim)
    end

    # @return [Array(Numeric, Numeric)] The [max, median] heat strain index, medianed over
    #   positive samples only since CORE emits long zero runs when thermoneutral. [nil, nil]
    #   when the stream is absent or empty.
    def heat_strain_values(activity)
      return [ nil, nil ] unless activity[:stream_types]&.include?("heat_strain_index")

      samples = stream_data(activity[:id], "heat_strain_index")
      return [ nil, nil ] if samples.blank?

      positive = samples.select(&:positive?)
      [ round_tenth(samples.max), round_tenth(median(positive.presence || samples) || 0) ]
    end

    # @return [Array<Numeric>, nil] The named stream's numeric samples.
    def stream_data(activity_id, type)
      streams = @intervals.activity_streams(activity_id, types: [ type, "time" ])
      stream = Array(streams).find { |candidate| candidate[:type] == type }
      stream&.dig(:data)&.compact&.select { |value| value.is_a?(Numeric) }
    end

    def median(values)
      return if values.blank?

      sorted = values.sort
      middle = sorted.length / 2
      sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
    end

    def round_tenth(value)
      (value * 10).round / 10.0
    end

    # The activity's local calendar date (start_date_local is already athlete-local).
    #
    # ⚠️ Nil-safe on purpose. heat_line reaches this outside the `swallow` wrappers its sibling
    # steps use, so an activity missing start_date_local used to fail the whole run — and since
    # that failure is deterministic, ApplicationJob's 24-hour window then retried it all day.
    # @return [Date, nil]
    def activity_date(activity)
      local = activity[:start_date_local]
      return if local.blank?

      Date.parse(local[0, 10])
    rescue ArgumentError, TypeError
      nil
    end

    # Indoor = trainer flag, a "virtual" activity type, or a Zwift source.
    def indoor?(activity)
      activity[:trainer] == true ||
        activity[:type].to_s.downcase.include?("virtual") ||
        activity[:source].to_s.casecmp("zwift").zero?
    end

    # Runs a best-effort step, swallowing any failure so one flaky source loses only its own
    # line rather than the whole description.
    #
    # ⚠️ Not named `safely`: that's UpstreamIsolation's, with a different signature, and this
    # one's failures would otherwise look like they reached Bugsnag when they didn't.
    # @param fallback [Object] Value returned when the block raises (nil for a dropped line,
    #   [] for a collection).
    def swallow(label, fallback: nil)
      yield
    rescue StandardError => e
      log_warn("#{label} failed: #{e.message}")
      ErrorReporter.report_upstream(e, service: "ActivityDescription", context: label)
      fallback
    end

    def with_dedup_lock(activity_id)
      key = "whoop:description_lock:#{activity_id}"
      unless $redis.set(key, "1", nx: true, ex: LOCK_TTL.to_i)
        log_info("activity #{activity_id}: description already being generated — skipping duplicate")
        return
      end

      begin
        yield
      ensure
        $redis.del(key)
      end
    end

    def log_info(message)
      Rails.logger.info("#{LOG_PREFIX} #{message}")
    end

    def log_warn(message)
      Rails.logger.warn("#{LOG_PREFIX} #{message}")
    end
  end
end
