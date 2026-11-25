module ActivityDescription
  # The GPS track of an activity, from the `latlng` and `time` streams of Intervals.icu: its points,
  # a sample of them each minute, and its legs. It is geometry only, and it makes no request.
  class Track
    # The time between two samples of the track, and also the last point. A sample costs no
    # WeatherKit call: TrackWeather decides the calls.
    SAMPLE_SECONDS = 60
    # The length of one leg of the headwind measurement. A shorter leg reads GPS noise as a
    # direction, and a longer one cuts the corners of a road with many turns.
    LEG_METERS = 50
    # A step between two GPS points is moving time only when it is this short and this fast. A
    # longer step is a pause, and a slower one is a stop with GPS drift.
    MAX_STEP_SECONDS = 60
    MIN_MOVING_MPS = 1.0
    EARTH_RADIUS_METERS = 6_371_000.0

    # @param streams [Array<Hash>] The `latlng` and `time` streams. A `latlng` stream holds the
    #   latitudes in `data` and the longitudes in `data2`.
    def initialize(streams)
      @streams = Array(streams)
    end

    # @return [Array<Hash>] Each GPS point with a numeric position, as { offset:, latitude:,
    #   longitude:, meters:, index: }, where `meters` is the distance along the track.
    def points
      return @points if defined?(@points)

      times = stream("time")&.dig(:data)
      latlng = stream("latlng")
      latitudes = latlng&.dig(:data)
      longitudes = latlng&.dig(:data2)
      return @points = [] if times.blank? || latitudes.blank? || longitudes.blank?

      previous = nil
      meters = 0.0
      @points = times.each_with_index.filter_map do |offset, index|
        latitude = latitudes[index]
        longitude = longitudes[index]
        next unless offset.is_a?(Numeric) && latitude.is_a?(Numeric) && longitude.is_a?(Numeric)

        point = { offset: offset, latitude: latitude.to_f, longitude: longitude.to_f, index: index }
        meters += distance(previous, point) if previous
        previous = point
        point.merge(meters: meters)
      end
    end

    # One point each SAMPLE_SECONDS, and also the last point. Each sample has `seconds`, the time
    # that it counts for: from the midpoint before it to the midpoint after it.
    # @return [Array<Hash>] The points of the sample, each with :seconds.
    def samples
      @samples ||= weigh(sampled_points)
    end

    # The track in legs of LEG_METERS, for the headwind, as { offset:, bearing:, seconds: }. A leg
    # starts at a point and ends at the first point LEG_METERS from it. Its seconds are the moving
    # time only (refer to MAX_STEP_SECONDS), thus a pause or a stop does not count as wind.
    # @return [Array<Hash>]
    def legs
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

    private

    def stream(type)
      @streams.find { |candidate| candidate[:type] == type }
    end

    def sampled_points
      return [] if points.empty?

      sampled = []
      next_offset = points.first[:offset]
      points.each do |point|
        next if point[:offset] < next_offset

        sampled << point
        next_offset = point[:offset] + SAMPLE_SECONDS
      end
      sampled << points.last unless sampled.last[:index] == points.last[:index]
      sampled
    end

    # A track of one moment gives each sample the same weight.
    def weigh(sampled)
      weighted = sampled.each_with_index.map do |sample, index|
        before = index.zero? ? sample[:offset] : (sampled[index - 1][:offset] + sample[:offset]) / 2.0
        after = index == sampled.size - 1 ? sample[:offset] : (sample[:offset] + sampled[index + 1][:offset]) / 2.0
        sample.merge(seconds: after - before)
      end
      weighted.each { |sample| sample[:seconds] = 1.0 } if weighted.sum { |sample| sample[:seconds] }.zero?
      weighted
    end

    # @return [Float] The distance between two points, in meters.
    def distance(a, b)
      lat1 = a[:latitude] * Math::PI / 180
      lat2 = b[:latitude] * Math::PI / 180
      dlat = lat2 - lat1
      dlon = (b[:longitude] - a[:longitude]) * Math::PI / 180
      h = (Math.sin(dlat / 2)**2) + (Math.cos(lat1) * Math.cos(lat2) * (Math.sin(dlon / 2)**2))
      2 * EARTH_RADIUS_METERS * Math.asin(Math.sqrt(h))
    end

    # @return [Float] The direction of travel from one point to the next, in degrees from north.
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
