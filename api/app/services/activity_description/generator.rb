module ActivityDescription
  # Makes a description for an Intervals.icu activity that Strava can show, corrects the name of
  # the activity, then PUTs both back. It controls the collection of the data, the two lines that
  # Anthropic writes, and the block functions of Composer.
  class Generator
    # This goes at the start of each log line from this generator, thus you can find them with
    # grep.
    LOG_PREFIX = "Description:"

    # The activity types that can get a description: a swim, a bike ride, or a run only.
    ELIGIBLE_SPORTS = %w[Cycling Running Swimming].freeze

    # The sports that can get the planned-workout headline from the LLM, that is, the 🗓️ line.
    HEADLINE_SPORTS = %w[Cycling Running].freeze

    # Removes a second quick trigger for one activity. Without this, the code would use two times
    # the LLM tokens and two runs would race at the final PUT. The TTL limits the time that a
    # worker that stops holds the lock.
    LOCK_TTL = 10.minutes

    def initialize(intervals: Intervals.new, trainer_road: nil)
      @intervals = intervals
      @trainer_road = trainer_road
    end

    # Makes the description for an activity and writes it.
    # @param activity_id [String, Integer] The Intervals.icu activity id.
    # @param whoop_strain [Float, nil] The Whoop strain for the 🔥 line, which is optional, or nil.
    #   The code then makes the description without that line, for example when the trigger is not
    #   Whoop.
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

    # The 🗓️ planned-workout summary: the one TrainerRoad workout whose name is in the name of the
    # activity, with the same characters and the same case. The LLM writes the summary. With no
    # match, or with more than one match, there is no headline. This applies to a bike ride and to
    # a run only.
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

    # @return [Array<Hash>] The planned workouts for the local date of the activity. It is empty
    #   when there is no feed in the configuration or when the fetch fails. Thus a calendar with a
    #   problem removes only this line.
    def planned_workouts_for(activity)
      swallow("TrainerRoad planned workouts", fallback: []) do
        date = activity_date(activity)
        next [] if date.nil?

        trainer_road = @trainer_road || TrainerRoad.new(@intervals.athlete_timezone)
        trainer_road.planned_workouts(date) || []
      end
    end

    # The weather sentence from the LLM ("{emoji} {sentence}"). An indoor activity never gets
    # one.
    # @return [String, nil]
    def weather_line(activity)
      return if indoor?(activity)

      text = @intervals.activity_weather_summary(activity[:id])
      return if text.blank?

      result = swallow("weather sentence") { Llm.weather_sentence(text) }
      return if result.nil?

      "#{result[:emoji]} #{result[:sentence]}"
    end

    # The 💧 water-temperature line, for an open-water swim only, from the temperature stream of
    # the activity.
    # @return [String, nil]
    def water_temp_line(activity, swim)
      return unless swim
      return unless activity[:stream_types]&.include?("temp")

      samples = stream_data(activity[:id], "temp")
      return if samples.blank?

      Composer.water_temp_block(median(samples), unit: @intervals.temperature_unit)
    end

    # The 🌡️ heat line: the heat-adaptation score of the day.
    # @return [String, nil]
    def heat_line(activity, swim)
      return if swim

      date = activity_date(activity)
      score = date && @intervals.wellness(date)&.dig(:CoreHeatAdaptationScore)

      Composer.heat_block(heat_adaptation_score: score, swim: swim)
    end

    # @return [Array<Numeric>, nil] The numeric samples of the stream with that name.
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

    # The local calendar date of the activity. start_date_local is already in the time of the
    # athlete.
    #
    # ⚠️ This accepts nil, on purpose. heat_line calls this outside the `swallow` methods that the
    # other steps use. Thus an activity with no start_date_local stopped the full run. That failure
    # always occurs, thus the 24-hour window of ApplicationJob then ran the job again all day.
    # @return [Date, nil]
    def activity_date(activity)
      local = activity[:start_date_local]
      return if local.blank?

      Date.parse(local[0, 10])
    rescue ArgumentError, TypeError
      nil
    end

    # An activity is indoor when it has the trainer flag, a "virtual" activity type, or a Zwift
    # source.
    def indoor?(activity)
      activity[:trainer] == true ||
        activity[:type].to_s.downcase.include?("virtual") ||
        activity[:source].to_s.casecmp("zwift").zero?
    end

    # Runs a step that can fail, and it catches each failure. Thus one source with a problem
    # removes only its own line, and not the full description.
    #
    # ⚠️ The name is not `safely`. That name belongs to UpstreamIsolation, which has different
    # parameters, and a failure here would then look like it reached Bugsnag when it did not.
    # @param fallback [Object] The value to return when the block raises: nil for a line that goes
    #   away, or [] for a collection.
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
