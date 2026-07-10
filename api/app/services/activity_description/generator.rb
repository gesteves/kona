module ActivityDescription
  # Composes a Strava-ready description for an Intervals.icu activity and PUTs it back.
  # Orchestrates the data gathering (activity, streams, planned workout, heat adaptation,
  # Last.fm scrobbles), the two Anthropic-backed lines, and the pure block builders in
  # Composer. Used by the Whoop workout.updated webhook; structured so a rake task or
  # endpoint could reuse it later.
  class Generator
    # Activity types eligible for a generated description — swim/bike/run only.
    ELIGIBLE_SPORTS = %w[Cycling Running Swimming].freeze

    # Sports eligible for the LLM planned-workout headline (🗓️ line).
    HEADLINE_SPORTS = %w[Cycling Running].freeze

    # Rapid duplicate triggers for the same activity (e.g. two workout.updated webhooks
    # ~100ms apart, or a retry overlapping a slow run) are deduped with a Redis lock —
    # two runs would spend 2× LLM tokens and race the final PUT. The TTL bounds a crashed
    # worker's hold; the lock is released as soon as a run finishes.
    LOCK_TTL = 10.minutes

    def initialize(intervals: Intervals.new, trainer_road: nil, lastfm: Lastfm.new)
      @intervals = intervals
      @trainer_road = trainer_road
      @lastfm = lastfm
    end

    # Generates and writes the description for an activity.
    # @param activity_id [String, Integer] The Intervals.icu activity id.
    # @param whoop_workout [Hash, nil] The matched normalized Whoop workout ({strain:, …}),
    #   or nil — the description is then composed without the 🔥 strain line.
    def generate!(activity_id, whoop_workout: nil)
      with_dedup_lock(activity_id) do
        run(activity_id, whoop_workout)
      end
    end

    private

    def run(activity_id, whoop_workout)
      activity = @intervals.activity!(activity_id)
      sport = ActivityMatcher.normalize_type(activity[:type])

      unless ELIGIBLE_SPORTS.include?(sport)
        Rails.logger.info("Description: activity #{activity_id} is not swim/bike/run (type=#{activity[:type] || 'unknown'}) — skipping")
        return
      end
      if activity[:pool_length].present?
        Rails.logger.info("Description: activity #{activity_id} is a pool swim — skipping")
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
        whoop: Composer.whoop_block(whoop_workout&.dig(:strain), swim: swim),
        music: music_line(activity)
      )

      if description.blank?
        Rails.logger.info("Description: activity #{activity_id}: composed description was empty — skipping write")
        return
      end

      @intervals.update_activity!(activity_id, description: description)
      Rails.logger.info("Description: activity #{activity_id}: description updated (#{description.length} chars)")
    end

    # The 🗓️ planned-workout summary. The single TrainerRoad planned workout whose name
    # appears *verbatim* (case-sensitively) in the completed activity's name is summarized
    # by the LLM; zero or ambiguous (≥2) matches mean no headline. Cycling and running only.
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
        Rails.logger.info("Description: no TR planned workout name appears in activity name #{activity[:name].inspect} — no headline")
        return
      end
      if matches.size > 1
        Rails.logger.warn("Description: ambiguous TR name match for activity #{activity[:name].inspect}: #{matches.map { |m| m[:name] }.join(', ')} — refusing to pick, skipping headline")
        return
      end

      description = matches.first[:description]
      return if description.blank?

      with_llm_rescue("planned summary") { Llm.planned_summary(description) }
    end

    # @return [Array<Hash>] The TrainerRoad planned workouts for the activity's local date;
    #   empty when no feed is configured or the fetch fails (best-effort — a broken calendar
    #   must not lose the rest of the description).
    def planned_workouts_for(activity)
      trainer_road = @trainer_road || TrainerRoad.new(@intervals.athlete_timezone)
      trainer_road.planned_workouts(activity_date(activity)) || []
    rescue StandardError => e
      Rails.logger.warn("Description: failed to fetch TrainerRoad planned workouts: #{e.message}")
      []
    end

    # The LLM weather sentence ("{emoji} {sentence}"). Indoor activities never get one.
    # @return [String, nil]
    def weather_line(activity)
      return if indoor?(activity)

      text = @intervals.activity_weather_summary(activity[:id])
      return if text.blank?

      result = with_llm_rescue("weather sentence") { Llm.weather_sentence(text) }
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

    # The 🌡️ heat line: max/median heat strain index from the activity's HSI stream (median
    # over positive samples only — CORE emits long zero runs when thermoneutral) plus the
    # daily CoreHeatAdaptationScore from the wellness record.
    # @return [String, nil]
    def heat_line(activity, swim)
      return if swim

      max_hsi = nil
      median_hsi = nil
      if activity[:stream_types]&.include?("heat_strain_index")
        samples = stream_data(activity[:id], "heat_strain_index")
        if samples.present?
          positive = samples.select(&:positive?)
          max_hsi = round_tenth(samples.max)
          median_hsi = round_tenth(median(positive.presence || samples) || 0)
        end
      end

      score = @intervals.wellness(activity_date(activity))&.dig(:CoreHeatAdaptationScore)
      score = nil unless score.is_a?(Numeric)

      Composer.heat_block(max_hsi: max_hsi, median_hsi: median_hsi, heat_adaptation_score: score, swim: swim)
    end

    # The 🎧 music line, from Last.fm scrobbles during the activity's UTC time window.
    # @return [String, nil]
    def music_line(activity)
      return unless @lastfm.configured?
      return if activity[:start_date].blank?

      start_time = Time.iso8601(activity[:start_date])
      duration = activity[:moving_time] || activity[:elapsed_time] || 0
      songs = @lastfm.played_songs_during(start_time, start_time + duration)

      Composer.music_block(songs)
    rescue StandardError => e
      Rails.logger.warn("Description: Last.fm lookup failed: #{e.message}")
      nil
    end

    # @return [Array<Numeric>, nil] The named stream's numeric samples.
    def stream_data(activity_id, type)
      streams = @intervals.activity_streams(activity_id, types: [type, "time"])
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
    def activity_date(activity)
      Date.parse(activity[:start_date_local][0, 10])
    end

    # Indoor = trainer flag, a "virtual" activity type, or a Zwift source.
    def indoor?(activity)
      activity[:trainer] == true ||
        activity[:type].to_s.downcase.include?("virtual") ||
        activity[:source].to_s.casecmp("zwift").zero?
    end

    # Runs an LLM call, logging and swallowing failures so one flaky call loses only its
    # own line — parity with domestique's Promise.allSettled split.
    def with_llm_rescue(label)
      yield
    rescue StandardError => e
      Rails.logger.warn("Description: #{label} call failed: #{e.message}")
      nil
    end

    def with_dedup_lock(activity_id)
      key = "whoop:description_lock:#{activity_id}"
      unless $redis.set(key, "1", nx: true, ex: LOCK_TTL.to_i)
        Rails.logger.info("Description: activity #{activity_id}: description already being generated — skipping duplicate")
        return
      end

      begin
        yield
      ensure
        $redis.del(key)
      end
    end
  end
end
