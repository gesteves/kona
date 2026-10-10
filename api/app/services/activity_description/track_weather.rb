module ActivityDescription
  # The weather at each point of a GPS track, at the time of that point, from the WeatherKit hours.
  #
  # The past data of WeatherKit is hourly, and one call gives each hour of one position. Thus the
  # time costs no call. The track gets one call in each cell of about 1 km that it crosses, and a
  # track point gets the weather of the two query points around it, mixed by the distance along the
  # track.
  #
  # ⚠️ It does not correct a temperature for the elevation. WeatherKit applies its own terrain at
  # each position, it does not say for which elevation each value is, and the valleys here often
  # have inversions.
  class TrackWeather
    # The size of a cell, in decimals of a degree: about 1 km. The past values of WeatherKit change
    # about each 1–2 km, thus a smaller cell adds calls and no detail.
    CELL_DECIMALS = 2
    # The most WeatherKit calls for one activity. A longer track gets an even share of its cells.
    MAX_CALLS = 500

    # The values that WeatherKit gives for each hour, and that the code interpolates in time and
    # mixes in space.
    LINEAR_FIELDS = %i[temperature temperatureApparent windSpeed windGust humidity precipitationIntensity].freeze
    # The rate of precipitation, in mm/h, from which a point is wet. Below it, the precipitation is
    # a trace.
    MIN_PRECIPITATION_MM_PER_HOUR = 0.05
    # The condition code for a wet point whose hour has a dry code, from the `precipitationType`
    # of WeatherKit. Each type has steps of [the rate below which the code applies, the code].
    # ⚠️ The condition codes of WeatherKit miss light rain: an hour with 0.4 mm/h can be "Cloudy".
    PRECIPITATION_CODES = {
      "rain" => [ [ 0.5, "Drizzle" ], [ 4.0, "Rain" ], [ Float::INFINITY, "HeavyRain" ] ],
      "snow" => [ [ 0.5, "Flurries" ], [ 4.0, "Snow" ], [ Float::INFINITY, "HeavySnow" ] ],
      "sleet" => [ [ Float::INFINITY, "Sleet" ] ],
      "hail" => [ [ Float::INFINITY, "Hail" ] ],
      "mixed" => [ [ Float::INFINITY, "MixedRainfall" ] ]
    }.freeze

    # @return [Integer] The WeatherKit calls so far.
    attr_reader :calls

    # @param points [Array<Hash>] The track points in time order, with :offset, :latitude,
    #   :longitude, and :meters, the distance along the track.
    # @param start [Time] The start of the activity.
    # @param weather_kit [#hourly] The source of the hours. The specs replace it.
    def initialize(points, start:, weather_kit: WeatherKit)
      @points = points
      @start = start
      @weather_kit = weather_kit
      @calls = 0
      @hours = {}
      @stopped = false
      @covered_to = Float::INFINITY
    end

    # The weather at a track point, at its time.
    # @param point [Hash] A track point, with :offset and :meters.
    # @return [Hash, nil] The LINEAR_FIELDS, :windDirection, :conditionCode, and :daylight. Nil
    #   with no hours for that point.
    def at(point)
      return if query_points.empty? || point[:meters] > @covered_to

      before, after = neighbors(point[:meters])
      time = @start + point[:offset]
      a = interpolate(before[:hours], time)
      b = after.equal?(before) ? a : interpolate(after[:hours], time)
      return finish(a || b) if a.nil? || b.nil?

      gap = after[:meters] - before[:meters]
      finish(mix(a, b, gap.positive? ? (point[:meters] - before[:meters]) / gap : 0.0))
    end

    # The points that got hours, in track order, as the track point with :hours. A query point with
    # no hours stops the calls, and the track after the last query point with hours gets no weather.
    # @return [Array<Hash>]
    def query_points
      @query_points ||= begin
        queried = []
        cell_points.each do |point|
          hours = hours_for(point)
          if hours.nil?
            @covered_to = queried.last ? queried.last[:meters] : -Float::INFINITY
            break
          end
          queried << point.merge(hours: hours)
        end
        queried
      end
    end

    private

    # The first track point in each cell that the track enters, and the last point. A cell that the
    # track enters again gets a query point again, and it shares the call. With more than MAX_CALLS
    # points, an even share of them.
    # @return [Array<Hash>]
    def cell_points
      points = []
      @points.each { |point| points << point if points.empty? || cell(point) != cell(points.last) }
      points << @points.last unless points.empty? || points.last.equal?(@points.last)
      return points if points.size <= MAX_CALLS

      points.values_at(*(0...MAX_CALLS).map { |index| (index * (points.size - 1) / (MAX_CALLS - 1.0)).round })
    end

    def cell(point) = [ point[:latitude].round(CELL_DECIMALS), point[:longitude].round(CELL_DECIMALS) ]

    # Gets the hours at the position of a point. The call goes to the position of the first point
    # in each cell, and each later point in that cell shares it.
    # ⚠️ The calls stop at the first position with no hours. Each call already tries again, thus an
    # outage, or an activity older than the history of WeatherKit, costs one call and not one call
    # for each cell. That keeps a long activity inside the lock of the generator.
    # @return [Hash{Time => Hash}, nil] The hours by their start time.
    def hours_for(point)
      key = cell(point)
      return @hours[key] if @hours.key?(key)
      return if @stopped

      @calls += 1
      hours = index_hours(@weather_kit.hourly(point[:latitude].round(4), point[:longitude].round(4), from: range_start, to: range_end))
      @stopped = true if hours.nil?
      @hours[key] = hours
    end

    # The range of each call: from the start hour to two hours after the hour of the end.
    # ⚠️ Do not widen it to share calls between activities. WeatherKit gives other values for the
    # latest hours when the range starts earlier.
    def range_start = @start.beginning_of_hour

    def range_end = (@start + @points.last[:offset]).beginning_of_hour + 2.hours

    # @return [Array(Hash, Hash)] The query points before and after a distance along the track.
    #   Before the first one or after the last one, both are the same point.
    def neighbors(meters)
      index = query_points.bsearch_index { |point| point[:meters] >= meters }
      return [ query_points.last, query_points.last ] if index.nil?
      return [ query_points[index], query_points[index] ] if index.zero? || query_points[index][:meters] == meters

      [ query_points[index - 1], query_points[index] ]
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

    # The weather at one moment and one position, from the hour before it and the hour after it.
    # @return [Hash, nil] The LINEAR_FIELDS, and the :windDirection, :conditionCode,
    #   :precipitationType, and :daylight of the nearest hour. Nil with no hour for that moment.
    def interpolate(hours, time)
      first = hours[time.beginning_of_hour]
      return if first.nil?

      second = hours[time.beginning_of_hour + 1.hour] || first
      # ⚠️ The codes come from the nearest hour, and the rates are linear. Thus the time of each
      # hour has the same error on each side. Apple says that an hour starts at `forecastStart`,
      # but its history gives the rain of Open-Meteo at the same stamp, and Open-Meteo stamps the
      # end of the hour.
      mix(first, second, (time - time.beginning_of_hour) / 3600.0)
    end

    # Mixes two weather values: linear for the LINEAR_FIELDS, a vector for the wind direction, and
    # the code, the precipitation type, and the daylight of the nearer one.
    # @param share [Float] The share of the second value, from 0 to 1.
    # @return [Hash]
    def mix(first, second, share)
      values = LINEAR_FIELDS.index_with do |field|
        a = first[field]
        b = second[field]
        next if a.nil? && b.nil?

        a = (a || b).to_f
        b = (b || a).to_f
        a + ((b - a) * share)
      end

      nearest = share < 0.5 ? first : second
      values[:windDirection] = mix_direction(first, second, share)
      values[:conditionCode] = nearest[:conditionCode]
      values[:precipitationType] = nearest[:precipitationType]
      values[:daylight] = nearest[:daylight]
      values
    end

    # ⚠️ A direction is an angle, thus the code mixes it as a vector. A plain average of 350° and
    # 10° gives 180°, which is the opposite wind.
    def mix_direction(first, second, share)
      x = 0.0
      y = 0.0
      [ [ first, 1 - share ], [ second, share ] ].each do |value, weight|
        next if value[:windDirection].nil?

        speed = [ value[:windSpeed].to_f, 0.1 ].max
        radians = value[:windDirection].to_f * Math::PI / 180
        x += Math.sin(radians) * speed * weight
        y += Math.cos(radians) * speed * weight
      end
      return if x.zero? && y.zero?

      (Math.atan2(x, y) * 180 / Math::PI) % 360
    end

    # The value of a point: a dry code with a measurable rate becomes a code of
    # PRECIPITATION_CODES, after the mix, from the mixed rate.
    # @return [Hash, nil]
    def finish(values)
      return if values.nil?

      code = wet_code(values[:conditionCode], values[:precipitationType], values[:precipitationIntensity])
      values.except(:precipitationType).merge(conditionCode: code)
    end

    # The condition code of a point. A code that is already precipitation stays the same.
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

    def precipitation_type(code) = code.present? && CONDITIONS.dig(code.to_sym, :precipitation)
  end
end
