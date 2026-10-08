module ActivityDescription
  # Makes a weather summary for the full track of an outdoor activity from the WeatherKit hours.
  # It takes a sample of the GPS track at a fixed interval, gets the hours for each area that the
  # track crosses, interpolates each sample in time, and then aggregates the samples by time.
  # WeatherSentence writes the words from the Hash that #summary gives. Each decision is here: the
  # condition, the rounded numbers, the units, and what the line omits.
  #
  # When WeatherKit has no data for the track, for example for an activity older than its history,
  # the summary comes from the weather of the Intervals.icu activity. That weather has no humidity
  # and no time of precipitation, thus that summary has neither. ⚠️ An activity with no GPS track
  # gets no weather from either source.
  class Weather
    # The time between two samples of the track.
    SAMPLE_SECONDS = 600
    # The first radius of an area. Each area gets one WeatherKit call.
    AREA_RADIUS_METERS = 5_000
    # The first altitude band of an area, in meters above or below the altitude of its first sample.
    # ⚠️ WeatherKit changes with the elevation, thus a climb out of the band starts a new area, and
    # the top of a pass does not get the weather of the valley.
    AREA_ALTITUDE_METERS = 150
    # The most WeatherKit calls for one activity. A longer route makes each area larger.
    MAX_AREAS = 12
    # The length of one leg of the headwind measurement. A shorter leg reads GPS noise as a
    # direction, and a longer one cuts the corners of a road with many turns.
    LEG_METERS = 50
    # A step between two GPS points is moving time only when it is this short and this fast. A
    # longer step is a pause, and a slower one is a stop with GPS drift.
    MAX_STEP_SECONDS = 60
    MIN_MOVING_MPS = 1.0
    # ⚠️ The emoji of a condition that config/conditions.yml does not have. It must be in
    # Composer::STAT_EMOJIS: a weather line with no stat emoji stays at the next run as text of the
    # owner, and the run adds a second weather line.
    FALLBACK_EMOJI = "🌡️".freeze
    # The emoji of a hot or a cold activity whose condition is not adverse weather. A hot activity
    # has a feels-like above HOT_FEELS_LIKE_CELSIUS (95°F) at some point, and a cold one has a
    # feels-like below COLD_FEELS_LIKE_CELSIUS (32°F) at some point. The temperature does not count.
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
    # A condition that is shorter than this is noise, and the sequence omits it.
    MIN_CONDITION_SECONDS = 900
    # ⚠️ The headwind is the wind within this angle of the direction of travel, on each side.
    # Intervals.icu uses sectors too (its headwind and tailwind do not add up to 100%), thus the
    # number keeps the meaning that it had.
    HEADWIND_DEGREES = 45
    # Below this mean wind speed, in km/h, the direction does not matter, and the summary has no
    # headwind.
    HEADWIND_MIN_KPH = 8
    # Below this share of the time, a headwind is not worth a word.
    HEADWIND_MIN_PERCENT = 50

    # The cloud cover, in percent, below which each condition applies, for the Intervals.icu
    # fallback, which has a cloud cover and no condition. Above the last step, it is Cloudy.
    CLOUD_CONDITIONS = [ [ 13, "Clear" ], [ 38, "MostlyClear" ], [ 63, "PartlyCloudy" ], [ 88, "MostlyCloudy" ] ].freeze
    # The sun is above the horizon above this elevation, in degrees: the refraction and the size of
    # the sun move the true sunrise below zero.
    SUNRISE_ELEVATION = -0.833

    # The values that WeatherKit gives for each hour, and that the code interpolates in time.
    LINEAR_FIELDS = %i[temperature temperatureApparent windSpeed windGust humidity precipitationIntensity].freeze
    # The rate of precipitation, in mm/h, from which a sample is wet. Below it, the precipitation
    # is a trace.
    MIN_PRECIPITATION_MM_PER_HOUR = 0.05
    # The condition code for a wet sample whose hour has a dry code, from the `precipitationType`
    # of WeatherKit. Each type has steps of [the rate below which the code applies, the code].
    # ⚠️ The condition codes of WeatherKit miss light rain: an hour with 0.4 mm/h can be "Cloudy".
    PRECIPITATION_CODES = {
      "rain" => [ [ 0.5, "Drizzle" ], [ 4.0, "Rain" ], [ Float::INFINITY, "HeavyRain" ] ],
      "snow" => [ [ 0.5, "Flurries" ], [ 4.0, "Snow" ], [ Float::INFINITY, "HeavySnow" ] ],
      "sleet" => [ [ Float::INFINITY, "Sleet" ] ],
      "hail" => [ [ Float::INFINITY, "Hail" ] ],
      "mixed" => [ [ Float::INFINITY, "MixedRainfall" ] ]
    }.freeze
    # The sky-cover codes that are almost the same. The main condition is the family with the most
    # time, named by its code with the most time. Each other code is a family of its own.
    SKY_FAMILIES = { "Clear" => :clear, "MostlyClear" => :clear, "PartlyCloudy" => :cloudy, "MostlyCloudy" => :cloudy }.freeze
    COMPASS = %w[N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW].freeze
    EARTH_RADIUS_METERS = 6_371_000.0

    # @param activity [Hash] The Intervals.icu activity. It needs `start_date`, in UTC.
    # @param streams [Array<Hash>] The `latlng`, `time`, and optional `altitude` streams of
    #   Intervals.icu. A `latlng` stream holds the latitudes in `data` and the longitudes in `data2`.
    # @param unit [Symbol] :celsius or :fahrenheit, from Intervals#temperature_unit. Fahrenheit
    #   also gives mph and inches.
    # @param headwind [Boolean] True to measure the headwind, which is for a bike ride only.
    # @param weather_kit [#hourly] The source of the hours. The specs replace it.
    # @param air_quality [#history] The source of the past AQI. The specs replace it.
    # @param intervals [#activity_weather_summary, nil] The source of the full weather summary for
    #   the fallback. With nil, the fallback reads the fields of the activity only.
    def initialize(activity, streams, unit:, headwind: false, weather_kit: WeatherKit, air_quality: GoogleAirQuality, intervals: nil)
      @activity = activity
      @streams = Array(streams)
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

    private

    def report
      return @report if defined?(@report)

      @report = build_report
    end

    def build_report
      start = start_time
      return if start.nil?

      samples = track_samples
      return if samples.empty?

      weighted = add_weights(samples)
      weathered_report(start, weighted) || intervals_report(start, weighted)
    end

    # The report from WeatherKit, over the full GPS track.
    # @return [Hash, nil] Nil when WeatherKit gives no data for most of the samples.
    def weathered_report(start, weighted)
      areas = group_into_areas(weighted)
      from = start.beginning_of_hour
      to = (start + weighted.last[:offset]).beginning_of_hour + 2.hours

      hours_by_area = areas.map do |area|
        hours = @weather_kit.hourly(area[:latitude], area[:longitude], from: from, to: to)
        index_hours(hours)
      end

      weathered = weighted.filter_map do |sample|
        hours = hours_by_area[sample[:area]]
        weather = hours && interpolate(hours, start + sample[:offset])
        weather && sample.merge(weather: weather)
      end
      return if weathered.size * 2 < weighted.size

      runs = condition_runs(weathered)
      main = main_condition(runs)
      summary = aggregate(weathered, runs, main)
      summary[:aqi] = highest_aqi(start, weighted)
      adverse = adverse?(main&.dig(:code)) || summary[:precipitation].present?
      emoji = report_emoji(
        condition_emoji(main), adverse: adverse, start: start, samples: weighted,
        feels_like: weathered.map { |sample| sample[:weather][:temperatureApparent] }
      )
      { summary: summary.compact, emoji: emoji }
    end

    # The report from the weather of the Intervals.icu activity: its temperatures, its wind range
    # and highest gust, its prevailing wind, its headwind, its cloud cover, and its highest rain,
    # showers, and snow. The condition comes from the cloud cover, or from the precipitation.
    # @return [Hash, nil] Nil when the activity has no weather in Intervals.icu either.
    def intervals_report(start, weighted)
      return unless @activity[:has_weather] && @activity[:min_weather_temp] && @activity[:max_weather_temp]

      data = intervals_weather
      code = intervals_condition(data)
      temperatures = rounded_range(data[:min_weather_temp], data[:max_weather_temp]) { |value| temperature(value) }
      feels_like = rounded_range(data[:min_feels_like], data[:max_feels_like]) { |value| temperature(value) }
      wind = intervals_wind(data)

      summary = {
        units: units,
        condition: condition_phrase(code),
        temperature: temperatures,
        feels_like: (feels_like unless feels_like == temperatures),
        wind: wind,
        aqi: highest_aqi(start, weighted)
      }
      headwind = data[:headwind_percent].to_f.round
      summary[:headwind_percent] = headwind if @headwind && wind && kph(data[:average_wind_speed]) >= HEADWIND_MIN_KPH && headwind >= HEADWIND_MIN_PERCENT

      middle = weighted[weighted.size / 2]
      daylight = daylight?(start + middle[:offset], middle[:latitude], middle[:longitude])
      emoji = report_emoji(
        condition_emoji(code: code, daylight: daylight), adverse: adverse?(code), start: start, samples: weighted,
        feels_like: data.values_at(:min_feels_like, :max_feels_like)
      )
      { summary: summary.compact, emoji: emoji }
    end

    # The emoji of the line: HOT_EMOJI or COLD_EMOJI for a hot or a cold activity with no adverse
    # weather, else the emoji of the condition, with the moon phase in place of NIGHT_EMOJI.
    # @param emoji [String] The emoji of the main condition.
    # @param adverse [Boolean] True when the condition is adverse weather, or when it rained or
    #   snowed during part of the activity.
    # @param feels_like [Array<Numeric, nil>] Each feels-like, in °C.
    # @return [String]
    def report_emoji(emoji, adverse:, feels_like:, start:, samples:)
      feels_like = feels_like.compact
      unless adverse || feels_like.empty?
        return HOT_EMOJI if feels_like.max > HOT_FEELS_LIKE_CELSIUS
        return COLD_EMOJI if feels_like.min < COLD_FEELS_LIKE_CELSIUS
      end
      return emoji unless emoji == NIGHT_EMOJI

      moon_emoji(start, samples) || emoji
    end

    # @return [Boolean] True for a code that config/conditions.yml marks as adverse weather.
    def adverse?(code) = code.present? && CONDITIONS.dig(code.to_sym, :adverse_weather) == true

    # The moon phase at the middle of the activity. A failure loses the phase only.
    # @return [String, nil] An emoji of MOON_EMOJI, or nil.
    def moon_emoji(start, samples)
      middle = samples[samples.size / 2]
      MOON_EMOJI[@weather_kit.moon_phase(middle[:latitude], middle[:longitude], start + middle[:offset])]
    rescue StandardError => e
      ErrorReporter.report_upstream(e, service: "WeatherKit", context: "activity moon phase")
      nil
    end

    # The fields of the activity, with the fields of the full weather summary over them. The
    # activity has an average wind and an average gust only, and no showers.
    # @return [Hash]
    def intervals_weather
      extra = @activity[:id] && @intervals&.activity_weather_summary(@activity[:id])
      @activity.merge(extra.to_h.compact)
    end

    # Snow and rain first, then the cloud cover. The precipitation values are the highest rates of
    # the activity, thus any amount names the condition. ⚠️ Intervals.icu keeps the showers apart
    # from the rain, thus an activity with showers alone has a `max_rain` of zero.
    # @return [String] A condition code of config/conditions.yml.
    def intervals_condition(data)
      rain = (data[:max_rain].to_f + data[:max_showers].to_f).positive?
      snow = data[:max_snow].to_f.positive?
      return "MixedRainAndSnow" if rain && snow
      return "Snow" if snow
      return "Rain" if rain

      clouds = data[:average_clouds].to_f
      CLOUD_CONDITIONS.find { |limit, _code| clouds < limit }&.last || "Cloudy"
    end

    # @param mps [Numeric, nil] A speed in m/s, which is the unit of Intervals.icu.
    # @return [Float] The speed in km/h.
    def kph(mps) = mps.to_f * 3.6

    # The wind of the fallback, in the shape of #wind. With no range in the data, the range is the
    # average alone, and with no highest gust, the gust is the average gust.
    # @return [Hash, nil]
    def intervals_wind(data)
      average = data[:average_wind_speed]
      speeds = rounded_range(data[:min_wind_speed] || average, data[:max_wind_speed] || average) { |value| speed(kph(value)) }
      return if speeds.nil? || speeds[:max].zero?

      gust = speed(kph(data[:max_wind_gust] || data[:average_wind_gust])).round
      degrees = data[:prevailing_wind_deg]
      {
        direction: (compass(degrees) if degrees),
        speed: speeds,
        gust: (gust if gust > speeds[:max])
      }.compact
    end

    def rounded_range(min, max)
      return if min.nil? || max.nil?

      { min: yield(min.to_f).round, max: yield(max.to_f).round }
    end

    # Tells if the sun is above the horizon, from the NOAA approximation of the position of the sun.
    # The fallback has no daylight flag, and the emoji of a clear night is not the emoji of a clear day.
    # @see https://gml.noaa.gov/grad/solcalc/solareqns.PDF
    # @return [Boolean]
    def daylight?(time, latitude, longitude)
      time = time.utc
      hour = time.hour + (time.min / 60.0) + (time.sec / 3600.0)
      gamma = 2 * Math::PI / 365 * (time.yday - 1 + ((hour - 12) / 24))
      equation_of_time = 229.18 * (0.000075 + (0.001868 * Math.cos(gamma)) - (0.032077 * Math.sin(gamma)) -
                                   (0.014615 * Math.cos(2 * gamma)) - (0.040849 * Math.sin(2 * gamma)))
      declination = 0.006918 - (0.399912 * Math.cos(gamma)) + (0.070257 * Math.sin(gamma)) -
                    (0.006758 * Math.cos(2 * gamma)) + (0.000907 * Math.sin(2 * gamma)) -
                    (0.002697 * Math.cos(3 * gamma)) + (0.00148 * Math.sin(3 * gamma))
      solar_minutes = (hour * 60) + equation_of_time + (4 * longitude)
      hour_angle = ((solar_minutes / 4) - 180) * Math::PI / 180
      lat = latitude * Math::PI / 180
      cos_zenith = (Math.sin(lat) * Math.sin(declination)) + (Math.cos(lat) * Math.cos(declination) * Math.cos(hour_angle))
      elevation = 90 - (Math.acos(cos_zenith.clamp(-1.0, 1.0)) * 180 / Math::PI)
      elevation > SUNRISE_ELEVATION
    end

    # The highest AQI of three points: the start, the middle, and the end of the activity. Air
    # quality changes slowly, thus three points are enough. A point that fails loses its reading only.
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

    def stream(type)
      @streams.find { |candidate| candidate[:type] == type }
    end

    # @return [Array<Hash>] Each GPS point with a numeric position, as { offset:, latitude:,
    #   longitude:, altitude: }. The altitude is nil when the activity has no altitude stream.
    def track_points
      return @track_points if defined?(@track_points)

      times = stream("time")&.dig(:data)
      latlng = stream("latlng")
      latitudes = latlng&.dig(:data)
      longitudes = latlng&.dig(:data2)
      altitudes = stream("altitude")&.dig(:data) || []
      return @track_points = [] if times.blank? || latitudes.blank? || longitudes.blank?

      @track_points = times.each_with_index.filter_map do |offset, index|
        latitude = latitudes[index]
        longitude = longitudes[index]
        next unless offset.is_a?(Numeric) && latitude.is_a?(Numeric) && longitude.is_a?(Numeric)

        altitude = altitudes[index]
        altitude = nil unless altitude.is_a?(Numeric)
        { offset: offset, latitude: latitude.to_f, longitude: longitude.to_f, altitude: altitude&.to_f, index: index }
      end
    end

    # One point each SAMPLE_SECONDS, and also the last point.
    def track_samples
      points = track_points
      return [] if points.empty?

      samples = []
      next_offset = points.first[:offset]
      points.each do |point|
        next if point[:offset] < next_offset

        samples << point
        next_offset = point[:offset] + SAMPLE_SECONDS
      end
      samples << points.last unless samples.last[:index] == points.last[:index]
      samples
    end

    # The track in legs of LEG_METERS, for the headwind, as { offset:, bearing:, seconds: }. A leg
    # starts at a point and ends at the first point LEG_METERS from it. Its seconds are the moving
    # time only (refer to MAX_STEP_SECONDS), thus a pause or a stop does not count as wind.
    # @return [Array<Hash>]
    def track_legs
      points = track_points
      return [] if points.size < 2

      legs = []
      origin = points.first
      seconds = 0.0
      points.each_cons(2) do |a, b|
        step = b[:offset] - a[:offset]
        seconds += step if step.positive? && step <= MAX_STEP_SECONDS && distance(a, b) >= MIN_MOVING_MPS * step
        next if distance(origin, b) < LEG_METERS

        legs << { offset: origin[:offset], bearing: bearing(origin, b), seconds: seconds }
        origin = b
        seconds = 0.0
      end
      legs
    end

    # Each sample counts for the time from the midpoint before it to the midpoint after it. A track
    # of one moment gives each sample the same weight.
    def add_weights(samples)
      weighted = samples.each_with_index.map do |sample, index|
        before = index.zero? ? sample[:offset] : (samples[index - 1][:offset] + sample[:offset]) / 2.0
        after = index == samples.size - 1 ? sample[:offset] : (sample[:offset] + samples[index + 1][:offset]) / 2.0
        sample.merge(seconds: after - before)
      end
      weighted.each { |sample| sample[:seconds] = 1.0 } if weighted.sum { |sample| sample[:seconds] }.zero?
      weighted
    end

    # Puts each sample in the first area whose center is within the radius and the altitude band,
    # or in a new area. A sample or a center with no altitude matches each band. With more than
    # MAX_AREAS, it starts again with a larger radius and a larger band.
    # @return [Array<Hash>] The areas, as { latitude:, longitude: }. Each sample gets an :area index.
    def group_into_areas(samples)
      radius = AREA_RADIUS_METERS
      band = AREA_ALTITUDE_METERS
      loop do
        centers = []
        samples.each do |sample|
          area = centers.index { |center| distance(center, sample) <= radius && in_band?(center, sample, band) }
          if area.nil?
            centers << sample.slice(:latitude, :longitude, :altitude)
            area = centers.size - 1
          end
          sample[:area] = area
        end
        return centers.map { |center| { latitude: center[:latitude].round(2), longitude: center[:longitude].round(2) } } if centers.size <= MAX_AREAS

        radius *= 1.5
        band *= 1.5
      end
    end

    def in_band?(center, sample, band)
      center[:altitude].nil? || sample[:altitude].nil? || (center[:altitude] - sample[:altitude]).abs <= band
    end

    # @return [Hash{Time => Hash}, nil] The hours by their start time.
    def index_hours(hours)
      return if hours.blank?

      hours.each_with_object({}) do |hour, index|
        start = Time.iso8601(hour[:forecastStart].to_s)
        index[start] = hour
      rescue ArgumentError
        next
      end.presence
    end

    # The weather at one moment, from the hour before it and the hour after it.
    # @return [Hash, nil]
    def interpolate(hours, time)
      first = hours[time.beginning_of_hour]
      return if first.nil?

      second = hours[time.beginning_of_hour + 1.hour] || first
      fraction = (time - time.beginning_of_hour) / 3600.0

      values = LINEAR_FIELDS.index_with do |field|
        a = first[field]
        b = second[field]
        next if a.nil? && b.nil?

        a = (a || b).to_f
        b = (b || a).to_f
        a + ((b - a) * fraction)
      end

      # ⚠️ The codes come from the nearest hour, and the rates are linear. Thus the time of each
      # hour has the same error on each side. Apple says that an hour starts at `forecastStart`,
      # but its history gives the rain of Open-Meteo at the same stamp, and Open-Meteo stamps the
      # end of the hour.
      nearest = fraction < 0.5 ? first : second
      values[:windDirection] = interpolate_direction(first, second, fraction)
      values[:conditionCode] = wet_code(nearest[:conditionCode], nearest[:precipitationType], values[:precipitationIntensity])
      values[:daylight] = nearest[:daylight]
      values
    end

    # The condition code of a sample. A dry code with a measurable rate of precipitation becomes a
    # code of PRECIPITATION_CODES. A code that is already precipitation stays the same.
    # @param code [String, nil] The condition code of the hour.
    # @param type [String, nil] The `precipitationType` of the hour, for example "rain".
    # @param intensity [Float, nil] The rate of precipitation, in mm/h.
    # @return [String, nil]
    def wet_code(code, type, intensity)
      return code if code.present? && precipitation_type(code)
      return code if intensity.to_f < MIN_PRECIPITATION_MM_PER_HOUR

      steps = PRECIPITATION_CODES[type.to_s.downcase]
      return code if steps.nil?

      steps.find { |limit, _code| intensity < limit }.last
    end

    # ⚠️ A direction is an angle, thus the code interpolates it as a vector. A plain average of 350°
    # and 10° gives 180°, which is the opposite wind.
    def interpolate_direction(first, second, fraction)
      x = 0.0
      y = 0.0
      [ [ first, 1 - fraction ], [ second, fraction ] ].each do |hour, share|
        next if hour[:windDirection].nil?

        speed = [ hour[:windSpeed].to_f, 0.1 ].max
        radians = hour[:windDirection].to_f * Math::PI / 180
        x += Math.sin(radians) * speed * share
        y += Math.cos(radians) * speed * share
      end
      return if x.zero? && y.zero?

      (Math.atan2(x, y) * 180 / Math::PI) % 360
    end

    # The condition code of the SKY_FAMILIES family with the most time in the runs, and whether most
    # of that time was in daylight. Thus 30% clear and 25% mostly clear win against 45% partly
    # cloudy. ⚠️ It reads the runs and not the samples, thus a short run that joined its neighbor
    # cannot be the main condition.
    # @return [Hash, nil] { code:, daylight: }
    def main_condition(runs)
      return if runs.empty?

      seconds_of = ->(group) { group.sum { |run| run[:seconds] } }
      _family, family_runs = runs.group_by { |run| SKY_FAMILIES.fetch(run[:code], run[:code]) }.max_by { |_key, same| seconds_of.call(same) }
      code, group = family_runs.group_by { |run| run[:code] }.max_by { |_code, same| seconds_of.call(same) }
      seconds = group.sum { |run| run[:seconds] }
      night = group.sum { |run| run[:night] }
      { code: code, daylight: night * 2 <= seconds }
    end

    # @param main [Hash, nil] { code:, daylight: }, or nil with no condition.
    # @return [String] The emoji of the condition, or FALLBACK_EMOJI.
    def condition_emoji(main)
      emoji = main && CONDITIONS.dig(main[:code].to_sym, :emoji)
      emoji = emoji[main[:daylight] ? :day : :night] if emoji.is_a?(Hash)
      emoji || FALLBACK_EMOJI
    end

    # The words of a condition code, from the `simplified` phrase of config/conditions.yml.
    def condition_phrase(code)
      CONDITIONS.dig(code.to_sym, :phrases, :simplified) || code.underscore.humanize
    end

    def aggregate(samples, runs, main)
      share = ->(sample) { sample[:seconds] }
      temperatures = range(samples, :temperature) { |value| temperature(value) }
      feels_like = range(samples, :temperatureApparent) { |value| temperature(value) }

      result = {
        units: units,
        condition: main && condition_phrase(main[:code]),
        temperature: temperatures,
        feels_like: (feels_like unless feels_like == temperatures),
        wind: wind(samples, share),
        humidity_percent: humidity_percent(samples, share),
        precipitation: precipitation_spell(runs, main)
      }
      if headwind?(samples, share)
        percent = headwind_percent(samples)
        result[:headwind_percent] = percent if percent && percent >= HEADWIND_MIN_PERCENT
      end
      result.compact
    end

    def units
      @imperial ? { temperature: "°F", wind: "mph" } : { temperature: "°C", wind: "km/h" }
    end

    def temperature(celsius) = @imperial ? (celsius * 9.0 / 5) + 32 : celsius

    def speed(kph) = @imperial ? kph * 0.621371 : kph

    def range(samples, field)
      values = samples.filter_map { |sample| sample[:weather][field] }
      return if values.empty?

      { min: yield(values.min).round, max: yield(values.max).round }
    end

    # @return [Integer, nil] The mean humidity, in percent, or nil when WeatherKit gives none.
    def humidity_percent(samples, share)
      humidity = mean(samples, :humidity, share)
      humidity && (humidity * 100).round
    end

    def mean(samples, field, share)
      present = samples.reject { |sample| sample[:weather][field].nil? }
      weight = present.sum(&share)
      return if present.empty? || weight.zero?

      present.sum { |sample| sample[:weather][field] * share.call(sample) } / weight
    end

    def wind(samples, share)
      speeds = range(samples, :windSpeed) { |value| speed(value) }
      return if speeds.nil?
      # A wind that rounds to zero is not worth a word, thus the summary has no wind at all.
      return if speeds[:max].zero?

      # The highest gust only, and only when it is more than the top of the wind range.
      gusts = range(samples, :windGust) { |value| speed(value) }
      gust = gusts[:max] if gusts && gusts[:max] > speeds[:max]
      { direction: mean_direction(samples, share), speed: speeds, gust: gust }.compact
    end

    # The direction of the vector mean of the wind, weighted by its speed and its time.
    def mean_direction(samples, share)
      x = 0.0
      y = 0.0
      samples.each do |sample|
        direction = sample[:weather][:windDirection]
        next if direction.nil?

        radians = direction * Math::PI / 180
        weight = sample[:weather][:windSpeed].to_f * share.call(sample)
        x += Math.sin(radians) * weight
        y += Math.cos(radians) * weight
      end
      return if x.abs < 1e-9 && y.abs < 1e-9

      compass((Math.atan2(x, y) * 180 / Math::PI) % 360)
    end

    # @param degrees [Numeric] A direction.
    # @return [String] The point of the compass, for example "NNE".
    def compass(degrees) = COMPASS[((degrees + 11.25) / 22.5).floor % 16]

    # The runs of one condition in time order, as { code:, seconds:, night:, first:, last: }. A run
    # shorter than MIN_CONDITION_SECONDS joins the run before it, or the run after it at the start.
    def condition_runs(samples)
      runs = []
      samples.each do |sample|
        code = sample[:weather][:conditionCode].presence
        next if code.nil?

        night = sample[:weather][:daylight] == false ? sample[:seconds] : 0
        if runs.last && runs.last[:code] == code
          extend_run(runs.last, seconds: sample[:seconds], night: night, last: sample[:offset])
        else
          runs << { code: code, seconds: sample[:seconds], night: night, first: sample[:offset], last: sample[:offset] }
        end
      end

      merged = []
      runs.each do |run|
        if merged.any? && (run[:seconds] < MIN_CONDITION_SECONDS || merged.last[:code] == run[:code])
          extend_run(merged.last, **run.slice(:seconds, :night, :last))
        else
          merged << run.dup
        end
      end
      if merged.size > 1 && merged.first[:seconds] < MIN_CONDITION_SECONDS
        first = merged.shift
        merged.first[:first] = first[:first]
        merged.first[:seconds] += first[:seconds]
        merged.first[:night] += first[:night]
      end
      merged
    end

    def extend_run(run, seconds:, night:, last:)
      run[:seconds] += seconds
      run[:night] += night
      run[:last] = last
    end

    # The precipitation of another TYPE than the main condition, for part of the activity, as
    # { condition: }. Its word is the longest condition of that type. With more than one such type,
    # the one with the most time. The line gives no time: an hourly code cannot give minutes.
    # ⚠️ The type is what stops a repeat: rain with 20 minutes of drizzle is one type, thus the line
    # says "Rain" alone. The type comes from `precipitation` in config/conditions.yml, and not from
    # `adverse_weather`, which also marks wind, haze, smoke, fog, and cold.
    # @return [Hash, nil]
    def precipitation_spell(runs, main)
      main_type = main && precipitation_type(main[:code])
      by_type = runs.select { |run| precipitation_type(run[:code]) && precipitation_type(run[:code]) != main_type }
                    .group_by { |run| precipitation_type(run[:code]) }
      return if by_type.empty?

      _type, spell = by_type.max_by { |_key, group| group.sum { |run| run[:seconds] } }
      code, = spell.group_by { |run| run[:code] }.max_by { |_key, group| group.sum { |run| run[:seconds] } }
      { condition: condition_phrase(code).downcase }
    end

    def precipitation_type(code) = CONDITIONS.dig(code.to_sym, :precipitation)

    # @return [Boolean] True for a bike ride with a mean wind of at least HEADWIND_MIN_KPH.
    def headwind?(samples, share)
      @headwind && mean(samples, :windSpeed, share).to_f >= HEADWIND_MIN_KPH
    end

    # The share of the moving time where the wind comes from ahead. Each leg of #track_legs gets
    # the wind direction of the sample nearest to it in time, because the wind changes slowly.
    # ⚠️ WeatherKit gives the direction that the wind comes FROM. Thus a headwind is a wind
    # direction near the direction of travel, and not near its opposite.
    # @return [Integer, nil] Nil when no leg has moving time and a wind direction.
    def headwind_percent(samples)
      winds = samples.select { |sample| sample[:weather][:windDirection] }
      return if winds.empty?

      measured = track_legs.select { |leg| leg[:seconds].positive? }
      weight = measured.sum { |leg| leg[:seconds] }
      return if weight.zero?

      ahead = measured.select do |leg|
        wind = winds.min_by { |sample| (sample[:offset] - leg[:offset]).abs }[:weather][:windDirection]
        difference = (wind - leg[:bearing]).abs % 360
        [ difference, 360 - difference ].min <= HEADWIND_DEGREES
      end
      (ahead.sum { |leg| leg[:seconds] } * 100.0 / weight).round
    end

    def distance(a, b)
      lat1 = a[:latitude] * Math::PI / 180
      lat2 = b[:latitude] * Math::PI / 180
      dlat = lat2 - lat1
      dlon = (b[:longitude] - a[:longitude]) * Math::PI / 180
      h = (Math.sin(dlat / 2)**2) + (Math.cos(lat1) * Math.cos(lat2) * (Math.sin(dlon / 2)**2))
      2 * EARTH_RADIUS_METERS * Math.asin(Math.sqrt(h))
    end

    def bearing(a, b)
      lat1 = a[:latitude] * Math::PI / 180
      lat2 = b[:latitude] * Math::PI / 180
      dlon = (b[:longitude] - a[:longitude]) * Math::PI / 180
      x = Math.sin(dlon) * Math.cos(lat2)
      y = (Math.cos(lat1) * Math.sin(lat2)) - (Math.sin(lat1) * Math.cos(lat2) * Math.cos(dlon))
      (Math.atan2(x, y) * 180 / Math::PI) % 360
    end
  end
end
