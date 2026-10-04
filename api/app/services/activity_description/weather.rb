module ActivityDescription
  # Makes a weather summary for the full track of an outdoor activity from the WeatherKit hours.
  # It takes a sample of the GPS track at a fixed interval, gets the hours for each area that the
  # track crosses, interpolates each sample in time, and then aggregates the samples by time.
  # WeatherSentence writes the words from the Hash that #summary gives. Each decision is here: the
  # condition, the rounded numbers, the units, and what the line omits.
  class Weather
    # The time between two samples of the track.
    SAMPLE_SECONDS = 600
    # The first radius of an area. Each area gets one WeatherKit call.
    AREA_RADIUS_METERS = 10_000
    # The most WeatherKit calls for one activity. A longer route makes each area larger.
    MAX_AREAS = 8
    # The distance over which a sample measures its direction of travel. A shorter distance reads
    # GPS noise as a direction.
    BEARING_METERS = 200
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
    # The summary gives the humidity only at or above both of these: the mean humidity, in percent,
    # and the highest temperature, in °C.
    HUMID_PERCENT = 70
    HUMID_CELSIUS = 24

    # The values that WeatherKit gives for each hour, and that the code interpolates in time.
    LINEAR_FIELDS = %i[temperature temperatureApparent windSpeed windGust humidity].freeze
    COMPASS = %w[N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW].freeze
    EARTH_RADIUS_METERS = 6_371_000.0

    # @param activity [Hash] The Intervals.icu activity. It needs `start_date`, in UTC.
    # @param streams [Array<Hash>] The `latlng` and `time` streams of Intervals.icu. A `latlng`
    #   stream holds the latitudes in `data` and the longitudes in `data2`.
    # @param unit [Symbol] :celsius or :fahrenheit, from Intervals#temperature_unit. Fahrenheit
    #   also gives mph and inches.
    # @param headwind [Boolean] False for a swim, where the wind direction is not a headwind.
    # @param weather_kit [#hourly] The source of the hours. The specs replace it.
    # @param air_quality [#history] The source of the past AQI. The specs replace it.
    def initialize(activity, streams, unit:, headwind: true, weather_kit: WeatherKit, air_quality: GoogleAirQuality)
      @activity = activity
      @streams = Array(streams)
      @imperial = unit == :fahrenheit
      @headwind = headwind
      @weather_kit = weather_kit
      @air_quality = air_quality
    end

    # @return [Hash, nil] The weather of the full activity, in the units of the athlete, for
    #   WeatherSentence. Nil when the activity has no GPS track, or when WeatherKit gives no data for
    #   most of the samples.
    def summary = report&.dig(:summary)

    # @return [String, nil] The emoji of the main condition, for its day or its night, from
    #   config/conditions.yml. Nil when #summary is nil or when the condition is not in that file.
    def emoji = report&.dig(:emoji)

    private

    def report
      return @report if defined?(@report)

      @report = build_report
    end

    def build_report
      start = start_time
      samples = track_samples
      return if start.nil? || samples.empty?

      weighted = add_weights(samples)
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
      { summary: summary.compact, emoji: main && condition_emoji(main) }
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

    # @return [Array<Hash>] Each GPS point with a numeric position, as { offset:, latitude:, longitude: }.
    def track_points
      times = stream("time")&.dig(:data)
      latlng = stream("latlng")
      latitudes = latlng&.dig(:data)
      longitudes = latlng&.dig(:data2)
      return [] if times.blank? || latitudes.blank? || longitudes.blank?

      times.each_with_index.filter_map do |offset, index|
        latitude = latitudes[index]
        longitude = longitudes[index]
        next unless offset.is_a?(Numeric) && latitude.is_a?(Numeric) && longitude.is_a?(Numeric)

        { offset: offset, latitude: latitude.to_f, longitude: longitude.to_f, index: index }
      end
    end

    # One point each SAMPLE_SECONDS, and also the last point. Each sample has its direction of
    # travel, or nil where the athlete did not move BEARING_METERS.
    def track_samples
      points = track_points
      return [] if points.empty?

      samples = []
      next_offset = points.first[:offset]
      points.each_with_index do |point, position|
        next if point[:offset] < next_offset

        samples << point.merge(bearing: travel_bearing(points, position))
        next_offset = point[:offset] + SAMPLE_SECONDS
      end
      last = points.size - 1
      samples << points.last.merge(bearing: travel_bearing(points, last)) unless samples.last[:index] == points.last[:index]
      samples
    end

    # The direction from this point to the first point BEARING_METERS ahead. At the end of the
    # track it uses the first point BEARING_METERS behind.
    def travel_bearing(points, position)
      origin = points[position]
      ahead = points[(position + 1)..].find { |point| distance(origin, point) >= BEARING_METERS }
      return bearing(origin, ahead) if ahead

      behind = points[0...position].reverse.find { |point| distance(point, origin) >= BEARING_METERS }
      behind && bearing(behind, origin)
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

    # Puts each sample in the first area whose center is within the radius, or in a new area. With
    # more than MAX_AREAS, it starts again with a larger radius.
    # @return [Array<Hash>] The areas, as { latitude:, longitude: }. Each sample gets an :area index.
    def group_into_areas(samples)
      radius = AREA_RADIUS_METERS
      loop do
        centers = []
        samples.each do |sample|
          area = centers.index { |center| distance(center, sample) <= radius }
          if area.nil?
            centers << { latitude: sample[:latitude], longitude: sample[:longitude] }
            area = centers.size - 1
          end
          sample[:area] = area
        end
        return centers.map { |center| center.transform_values { |value| value.round(2) } } if centers.size <= MAX_AREAS

        radius *= 1.5
      end
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

      nearest = fraction < 0.5 ? first : second
      values[:windDirection] = interpolate_direction(first, second, fraction)
      values[:conditionCode] = nearest[:conditionCode]
      values[:daylight] = nearest[:daylight]
      values
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

    # The condition code with the most time in the runs, and whether most of that time was in
    # daylight. ⚠️ It reads the runs and not the samples, thus a short run that joined its neighbor
    # cannot be the main condition.
    # @return [Hash, nil] { code:, daylight: }
    def main_condition(runs)
      return if runs.empty?

      code, group = runs.group_by { |run| run[:code] }.max_by { |_code, same| same.sum { |run| run[:seconds] } }
      seconds = group.sum { |run| run[:seconds] }
      night = group.sum { |run| run[:night] }
      { code: code, daylight: night * 2 <= seconds }
    end

    def condition_emoji(main)
      emoji = CONDITIONS.dig(main[:code].to_sym, :emoji)
      emoji.is_a?(Hash) ? emoji[main[:daylight] ? :day : :night] : emoji
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
        percent = headwind_percent(samples, share)
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

    # @return [Integer, nil] The mean humidity, only when it is high in warm weather.
    def humidity_percent(samples, share)
      humidity = mean(samples, :humidity, share)
      hottest = samples.filter_map { |sample| sample[:weather][:temperature] }.max
      return if humidity.nil? || hottest.nil?
      return unless humidity * 100 >= HUMID_PERCENT && hottest >= HUMID_CELSIUS

      (humidity * 100).round
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

      degrees = (Math.atan2(x, y) * 180 / Math::PI) % 360
      COMPASS[((degrees + 11.25) / 22.5).floor % 16]
    end

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
    # { condition:, minutes: }. Its time is the total time of that type, and its word is the longest
    # condition of that type. With more than one such type, the one with the most time.
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
      { condition: condition_phrase(code).downcase, minutes: (spell.sum { |run| run[:seconds] } / 60.0).round }
    end

    def precipitation_type(code) = CONDITIONS.dig(code.to_sym, :precipitation)

    # @return [Boolean] True for an activity that is not a swim, with a mean wind of at least
    #   HEADWIND_MIN_KPH.
    def headwind?(samples, share)
      @headwind && mean(samples, :windSpeed, share).to_f >= HEADWIND_MIN_KPH
    end

    # The share of the time with a direction of travel where the wind comes from ahead.
    # ⚠️ WeatherKit gives the direction that the wind comes FROM. Thus a headwind is a wind
    # direction near the direction of travel, and not near its opposite.
    def headwind_percent(samples, share)
      measured = samples.select { |sample| sample[:bearing] && sample[:weather][:windDirection] }
      weight = measured.sum(&share)
      return if measured.empty? || weight.zero?

      ahead = measured.select do |sample|
        difference = (sample[:weather][:windDirection] - sample[:bearing]).abs % 360
        [ difference, 360 - difference ].min <= HEADWIND_DEGREES
      end
      (ahead.sum(&share) * 100.0 / weight).round
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
