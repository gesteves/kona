module ActivityDescription
  # Makes a weather summary for the full track of an outdoor activity from the WeatherKit hours.
  # It takes a sample of the GPS track each minute (Track), gets the weather of each sample from
  # TrackWeather, and then aggregates the samples by time. ConditionRuns decides the condition and
  # its facts. The numbers are here: the rounded values, the units, the emoji, and what the line
  # omits. WeatherSentence only writes the words.
  #
  # When WeatherKit has no data for the track, for example for an activity older than its history,
  # the summary comes from the weather of the Intervals.icu activity (IntervalsWeather). That
  # weather has no humidity and no time of precipitation, thus that summary has neither. ⚠️ An
  # activity with no GPS track gets no weather from either source.
  class Weather
    # ⚠️ The emoji of a condition that config/conditions.yml does not have. It must be in
    # Composer::STAT_EMOJIS: a weather line with no stat emoji stays at the next run as text of the
    # owner, and the run adds a second weather line.
    FALLBACK_EMOJI = "🌡️".freeze
    # The emoji of a hot or a cold activity whose condition is not adverse weather: a feels-like
    # above 35°C (95°F), or below 0°C (32°F), at some point. The temperature does not count.
    # ⚠️ These are not the limits of WeatherSummaryPresenter#hot? and #bad_weather?, on purpose:
    # the owner chose them for this emoji.
    HOT_FEELS_LIKE_CELSIUS = 35
    COLD_FEELS_LIKE_CELSIUS = 0
    HOT_EMOJI = "🥵".freeze
    COLD_EMOJI = "🥶".freeze
    # The night emoji of a clear sky. The moon phase of WeatherKit replaces it when it is available.
    NIGHT_EMOJI = "🌙".freeze
    # The emoji of each `moonPhase` of WeatherKit. Composer::STAT_EMOJIS holds each one.
    MOON_EMOJI = {
      "new" => "🌑", "waxingCrescent" => "🌒", "firstQuarter" => "🌓", "waxingGibbous" => "🌔",
      "full" => "🌕", "waningGibbous" => "🌖", "thirdQuarter" => "🌗", "waningCrescent" => "🌘"
    }.freeze
    # The least head component of the wind, in km/h, for a leg with a headwind. The head component
    # is the wind speed × the cosine of the angle between the wind and the direction of travel.
    # Thus a stronger wind counts from a wider angle. The Intervals.icu fallback has no wind for
    # each leg, thus it uses this value as the least mean wind.
    HEADWIND_MIN_KPH = 8
    # Below this share of the time, a headwind is not worth a word.
    HEADWIND_MIN_PERCENT = 50
    # The ActivityMatcher types that get the headwind.
    HEADWIND_TYPES = %w[Cycling Running].freeze
    COMPASS = %w[N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW].freeze

    # @return [Boolean] True for a bike ride and a run, which get the headwind. An indoor activity
    #   gets no weather line at all.
    def self.headwind?(activity) = HEADWIND_TYPES.include?(ActivityMatcher.normalize_type(activity[:type]))

    # @param activity [Hash] The Intervals.icu activity. It needs `start_date`, in UTC.
    # @param streams [Array<Hash>] The `latlng` and `time` streams of Intervals.icu. Refer to Track.
    # @param unit [Symbol] :celsius or :fahrenheit, from Intervals#temperature_unit. Fahrenheit
    #   also gives mph.
    # @param headwind [Boolean] True to measure the headwind. Refer to .headwind?.
    # @param weather_kit [#hourly] The source of the hours. The specs replace it.
    # @param air_quality [#history] The source of the past AQI. The specs replace it.
    # @param intervals [#activity_weather_summary, nil] The source of the full weather summary for
    #   the fallback. With nil, the fallback reads the fields of the activity only.
    def initialize(activity, streams, unit:, headwind: false, weather_kit: WeatherKit, air_quality: GoogleAirQuality, intervals: nil)
      @activity = activity
      @track = Track.new(streams)
      @imperial = unit == :fahrenheit
      @headwind = headwind
      @weather_kit = weather_kit
      @air_quality = air_quality
      @intervals = intervals
    end

    # @return [Hash, nil] The weather of the full activity, in the units of the athlete, for
    #   WeatherSentence. Nil when the activity has no GPS track, or when neither WeatherKit nor
    #   Intervals.icu has its weather.
    def summary = report&.dig(:summary)

    # @return [String, nil] The emoji of the main condition, for its day or its night, from
    #   config/conditions.yml, or FALLBACK_EMOJI. Nil only when #summary is nil.
    def emoji = report&.dig(:emoji)

    # The inspect task reads this to tune HEADWIND_MIN_KPH and HEADWIND_MIN_PERCENT.
    # @return [Integer, nil] The share of the moving time with a headwind, in percent, also below
    #   HEADWIND_MIN_PERCENT. Nil for an activity with no headwind measurement, and with no wind.
    def headwind_share = report&.dig(:headwind_share)

    # The weather along the track. The inspect task reads its calls and its query points.
    # @return [TrackWeather, nil] Nil with no start time.
    def track_weather
      return @track_weather if defined?(@track_weather)

      start = start_time
      @track_weather = start && TrackWeather.new(@track.points, start: start, weather_kit: @weather_kit)
    end

    private

    def report
      return @report if defined?(@report)

      @report = build_report
    end

    def build_report
      start = start_time
      return if start.nil?

      samples = @track.samples
      return if samples.empty?

      weatherkit_report(start, samples) || intervals_report(start, samples)
    end

    # The report from WeatherKit, over the full GPS track.
    # @return [Hash, nil] Nil when WeatherKit gives no data for most of the samples.
    def weatherkit_report(start, samples)
      weathered = samples.filter_map do |sample|
        weather = track_weather.at(sample)
        weather && sample.merge(weather: weather)
      end
      return if weathered.size * 2 < samples.size

      conditions = ConditionRuns.new(weathered)
      main = conditions.main
      summary = aggregate(weathered, conditions)
      summary[:aqi] = highest_aqi(start, samples)
      headwind = headwind_percent(weathered) if @headwind && summary[:wind]
      summary[:headwind_percent] = headwind if headwind && headwind >= HEADWIND_MIN_PERCENT
      adverse = ConditionCodes.adverse?(main&.dig(:code)) || summary[:precipitation].present?
      emoji = report_emoji(
        condition_emoji(main), adverse: adverse, start: start, samples: samples,
        feels_like: weathered.map { |sample| sample[:weather][:temperatureApparent] }
      )
      { summary: summary.compact, emoji: emoji, headwind_share: headwind }
    end

    # The report from the weather of the Intervals.icu activity. The condition comes from the cloud
    # cover, or from the precipitation.
    # @return [Hash, nil] Nil when the activity has no weather in Intervals.icu either.
    def intervals_report(start, samples)
      fallback = IntervalsWeather.new(@activity, intervals: @intervals)
      return unless fallback.available?

      code = fallback.condition_code
      temperatures = rounded_range(*fallback.temperatures) { |value| temperature(value) }
      feels_like = rounded_range(*fallback.feels_like) { |value| temperature(value) }
      wind = intervals_wind(fallback)

      summary = {
        units: units,
        condition: ConditionCodes.phrase(code),
        temperature: temperatures,
        feels_like: (feels_like unless feels_like == temperatures),
        wind: wind,
        aqi: highest_aqi(start, samples)
      }
      headwind = fallback.headwind_percent if @headwind && wind
      summary[:headwind_percent] = headwind if headwind && fallback.mean_wind_kph >= HEADWIND_MIN_KPH && headwind >= HEADWIND_MIN_PERCENT

      middle = samples[samples.size / 2]
      daylight = Solar.daylight?(start + middle[:offset], middle[:latitude], middle[:longitude])
      emoji = report_emoji(
        condition_emoji(code: code, daylight: daylight), adverse: ConditionCodes.adverse?(code), start: start, samples: samples,
        feels_like: fallback.feels_like
      )
      { summary: summary.compact, emoji: emoji, headwind_share: headwind }
    end

    # The wind of the fallback, in the shape of #wind. With no highest gust, the gust is the
    # average gust.
    # @return [Hash, nil]
    def intervals_wind(fallback)
      lowest, highest = fallback.wind_speeds_kph
      speeds = rounded_range(lowest, highest) { |value| speed(value) }
      return if speeds.nil? || speeds[:max].zero?

      gust = speed(fallback.gust_kph).round
      degrees = fallback.wind_degrees
      {
        direction: (compass(degrees) if degrees),
        speed: speeds,
        gust: (gust if gust > speeds[:max])
      }.compact
    end

    # The emoji of the line: HOT_EMOJI or COLD_EMOJI for a hot or a cold activity with no adverse
    # weather, else the emoji of the condition, with the moon phase in place of NIGHT_EMOJI.
    # @param adverse [Boolean] True when the condition is adverse weather, or when it rained or
    #   snowed during part of the activity.
    # @param feels_like [Array<Numeric, nil>] Each feels-like, in °C.
    def report_emoji(emoji, adverse:, feels_like:, start:, samples:)
      feels_like = feels_like.compact
      unless adverse || feels_like.empty?
        return HOT_EMOJI if feels_like.max > HOT_FEELS_LIKE_CELSIUS
        return COLD_EMOJI if feels_like.min < COLD_FEELS_LIKE_CELSIUS
      end
      return emoji unless emoji == NIGHT_EMOJI

      moon_emoji(start, samples) || emoji
    end

    # @param main [Hash, nil] { code:, daylight: }, or nil with no condition.
    # @return [String] The emoji of the condition, or FALLBACK_EMOJI.
    def condition_emoji(main)
      (main && ConditionCodes.emoji(main[:code], daylight: main[:daylight])) || FALLBACK_EMOJI
    end

    # The moon phase at the middle of the activity. A failure loses the phase only.
    # @return [String, nil] An emoji of MOON_EMOJI, or nil.
    def moon_emoji(start, samples)
      middle = samples[samples.size / 2]
      MOON_EMOJI[@weather_kit.moon_phase(middle[:latitude], middle[:longitude], start + middle[:offset])]
    rescue StandardError => e
      ErrorReporter.report_upstream(e, service: "WeatherKit", context: "activity moon phase")
      nil
    end

    # The highest AQI at the start, the middle, and the end of the activity. Air quality changes
    # slowly, thus three points are enough. A point that fails loses its reading only.
    # @return [Integer, nil]
    def highest_aqi(start, samples)
      middle = (samples.first[:offset] + samples.last[:offset]) / 2.0
      points = [ samples.first, samples.min_by { |sample| (sample[:offset] - middle).abs }, samples.last ].uniq

      points.filter_map do |point|
        @air_quality.history(point[:latitude], point[:longitude], start + point[:offset])
      rescue StandardError => e
        ErrorReporter.report_upstream(e, service: "GoogleAirQuality", context: "activity AQI")
        nil
      end.max
    end

    def start_time
      Time.iso8601(@activity[:start_date].to_s)
    rescue ArgumentError
      nil
    end

    # @param samples [Array<Hash>] The samples with weather, in time order.
    # @param conditions [ConditionRuns] The conditions of those samples.
    # @return [Hash] The summary of the WeatherKit report, with no AQI and no headwind.
    def aggregate(samples, conditions)
      main = conditions.main
      temperatures = range(samples, :temperature) { |value| temperature(value) }
      feels_like = range(samples, :temperatureApparent) { |value| temperature(value) }

      result = {
        units: units,
        condition: main && ConditionCodes.phrase(main[:code]),
        temperature: temperatures,
        feels_like: (feels_like unless feels_like == temperatures),
        wind: wind(samples),
        humidity_percent: humidity_percent(samples),
        precipitation: conditions.precipitation_spell
      }
      add_facts(result, conditions.facts(wind_kph: mean(samples, :windSpeed), cloud_cover: mean(samples, :cloudCover)))
      result.compact
    end

    # Puts the facts in the summary. A sky word alone is the condition, and it needs no LLM. Each
    # other set of facts goes to the LLM as `conditions`.
    # @param facts [Array<Array(String, String)>] The facts of ConditionRuns#facts.
    def add_facts(result, facts)
      if facts.map(&:first) == [ "Sky" ]
        result[:condition] = facts.first.last.upcase_first
      elsif facts.any?
        result[:conditions] = facts.map { |label, words| "#{label}: #{words}" }
      end
    end

    def units
      @imperial ? { temperature: "°F", wind: "mph" } : { temperature: "°C", wind: "km/h" }
    end

    def temperature(celsius) = @imperial ? (celsius * 9.0 / 5) + 32 : celsius

    def speed(kph) = @imperial ? kph * 0.621371 : kph

    # @return [Hash, nil] The lowest and the highest value of a weather field, as { min:, max: },
    #   each one through the block and rounded.
    def range(samples, field)
      values = samples.filter_map { |sample| sample[:weather][field] }
      return if values.empty?

      { min: yield(values.min).round, max: yield(values.max).round }
    end

    def rounded_range(min, max)
      return if min.nil? || max.nil?

      { min: yield(min.to_f).round, max: yield(max.to_f).round }
    end

    # @return [Integer, nil] The mean humidity, in percent, or nil when WeatherKit gives none.
    def humidity_percent(samples)
      humidity = mean(samples, :humidity)
      humidity && (humidity * 100).round
    end

    # @return [Float, nil] The mean of a weather field, weighted by the time of each sample.
    def mean(samples, field)
      present = samples.reject { |sample| sample[:weather][field].nil? }
      weight = present.sum { |sample| sample[:seconds] }
      return if present.empty? || weight.zero?

      present.sum { |sample| sample[:weather][field] * sample[:seconds] } / weight
    end

    def wind(samples)
      speeds = range(samples, :windSpeed) { |value| speed(value) }
      return if speeds.nil?
      # A wind that rounds to zero is not worth a word, thus the summary has no wind at all.
      return if speeds[:max].zero?

      # The highest gust only, and only when it is more than the top of the wind range.
      gusts = range(samples, :windGust) { |value| speed(value) }
      gust = gusts[:max] if gusts && gusts[:max] > speeds[:max]
      { direction: mean_direction(samples), speed: speeds, gust: gust }.compact
    end

    # The direction of the vector mean of the wind, weighted by its speed and its time.
    def mean_direction(samples)
      x = 0.0
      y = 0.0
      samples.each do |sample|
        direction = sample[:weather][:windDirection]
        next if direction.nil?

        radians = direction * Math::PI / 180
        weight = sample[:weather][:windSpeed].to_f * sample[:seconds]
        x += Math.sin(radians) * weight
        y += Math.cos(radians) * weight
      end
      return if x.abs < 1e-9 && y.abs < 1e-9

      compass((Math.atan2(x, y) * 180 / Math::PI) % 360)
    end

    # @return [String] The point of the compass of a direction in degrees, for example "NNE".
    def compass(degrees) = COMPASS[((degrees + 11.25) / 22.5).floor % 16]

    # The share of the moving time with a headwind. A leg of Track#legs has a headwind when its
    # head component is HEADWIND_MIN_KPH or more. Each leg gets the wind of the sample nearest to it
    # in time, because the wind changes slowly.
    # ⚠️ WeatherKit gives the direction that the wind comes FROM. Thus a headwind is a wind
    # direction near the direction of travel, and not near its opposite.
    # ⚠️ A leg with no sample inside Track::SAMPLE_SECONDS is past the WeatherKit coverage, and it
    # does not count. Each track point has a sample at most that time before it.
    # @param samples [Array<Hash>] The samples with weather, in time order.
    # @return [Integer, nil] Nil when no leg has moving time and a wind.
    def headwind_percent(samples)
      winds = samples.select { |sample| sample[:weather][:windDirection] && sample[:weather][:windSpeed] }
      return if winds.empty?

      # Both lists are in time order, thus one walk finds the nearest sample of each leg.
      nearest = 0
      measured = @track.legs.filter_map do |leg|
        next unless leg[:seconds].positive?

        nearest += 1 while nearest + 1 < winds.size &&
                           (winds[nearest + 1][:offset] - leg[:offset]).abs < (winds[nearest][:offset] - leg[:offset]).abs
        wind = winds[nearest]
        next if (wind[:offset] - leg[:offset]).abs > Track::SAMPLE_SECONDS

        radians = (wind[:weather][:windDirection] - leg[:bearing]) * Math::PI / 180
        leg.merge(ahead: wind[:weather][:windSpeed] * Math.cos(radians) >= HEADWIND_MIN_KPH)
      end
      weight = measured.sum { |leg| leg[:seconds] }
      return if weight.zero?

      (measured.select { |leg| leg[:ahead] }.sum { |leg| leg[:seconds] } * 100.0 / weight).round
    end
  end
end
