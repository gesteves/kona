module RaceWeather
  # Reads a GPX course, and gives the time of each part of it at an even speed. It also sorts each
  # leg by its wind, with the rule of the headwind in the api activity description. This file uses
  # the standard library only, thus spec/race_weather_check.rb can run it with no bundle.
  module Course
    extend self

    EARTH_RADIUS_METERS = 6_371_000.0
    # The length of one leg of the wind measurement, as in the api.
    LEG_METERS = 50
    # The least wind component, in km/h, for a leg with a headwind, a tailwind, or a crosswind. The
    # api uses this value for the headwind.
    WIND_MIN_KPH = 8
    WIND_KINDS = %i[headwind crosswind tailwind light].freeze

    # @param xml [String] The text of a GPX file.
    # @return [Array<Hash>] Each track point as { latitude:, longitude:, meters: }, where `meters` is
    #   the distance along the track. A file with no track point gives its route points.
    def points(xml)
      tags = xml.scan(/<trkpt\b([^>]*)>/).flatten
      tags = xml.scan(/<rtept\b([^>]*)>/).flatten if tags.empty?
      previous = nil
      meters = 0.0
      tags.filter_map do |attributes|
        latitude = attributes[/\blat="([-\d.]+)"/, 1]
        longitude = attributes[/\blon="([-\d.]+)"/, 1]
        next unless latitude && longitude

        point = { latitude: latitude.to_f, longitude: longitude.to_f }
        meters += distance(previous, point) if previous
        previous = point
        point.merge(meters: meters)
      end
    end

    # The course in legs of LEG_METERS. A leg starts at a point and ends at the first point
    # LEG_METERS from it. The last leg can be shorter.
    # @param points [Array<Hash>] The points of #points.
    # @return [Array<Hash>] Each leg as { start:, finish:, meters:, bearing: }, where `start` and
    #   `finish` are points.
    def legs(points)
      legs = []
      origin = points.first
      points.drop(1).each do |point|
        last = point.equal?(points.last)
        next if distance(origin, point) < LEG_METERS && !(last && point[:meters] > origin[:meters])

        legs << { start: origin, finish: point, meters: point[:meters] - origin[:meters], bearing: bearing(origin, point) }
        origin = point
      end
      legs
    end

    # @param kph [Float] The wind speed.
    # @param from_degrees [Float] The direction that the wind comes FROM, as WeatherKit gives it.
    # @param bearing [Float] The direction of travel.
    # @return [Symbol] :headwind, :tailwind, or :crosswind when that component is WIND_MIN_KPH or
    #   more, otherwise :light. A headwind or a tailwind wins against a crosswind, thus the headwind
    #   share is the same as in the api.
    def wind_kind(kph, from_degrees, bearing)
      radians = (from_degrees - bearing) * Math::PI / 180
      ahead = kph * Math.cos(radians)
      return :headwind if ahead >= WIND_MIN_KPH
      return :tailwind if ahead <= -WIND_MIN_KPH
      return :crosswind if (kph * Math.sin(radians)).abs >= WIND_MIN_KPH

      :light
    end

    # @param items [Array<Hash>] Each item with :kind and :weight.
    # @return [Hash{Symbol => Integer}] The share of the weight of each WIND_KINDS kind, in percent.
    def wind_shares(items)
      total = items.sum { |item| item[:weight] }
      WIND_KINDS.to_h do |kind|
        weight = items.select { |item| item[:kind] == kind }.sum { |item| item[:weight] }
        [kind, total.positive? ? (weight * 100.0 / total).round : 0]
      end
    end

    # @param text [String] A duration as "H:MM" or "H:MM:SS".
    # @return [Integer] The seconds.
    # @raise [ArgumentError] When the text is not a duration.
    def duration_seconds(text)
      parts = text.to_s.strip.split(':')
      raise ArgumentError, "#{text.inspect} is not H:MM or H:MM:SS" unless [2, 3].include?(parts.size) && parts.all? { |part| part.match?(/\A\d+\z/) }

      parts.map(&:to_i).reduce(0) { |seconds, part| (seconds * 60) + part } * (parts.size == 2 ? 60 : 1)
    end

    # @return [Float] The great-circle distance between two points, in meters.
    def distance(a, b)
      lat1 = a[:latitude] * Math::PI / 180
      lat2 = b[:latitude] * Math::PI / 180
      dlat = lat2 - lat1
      dlon = (b[:longitude] - a[:longitude]) * Math::PI / 180
      h = (Math.sin(dlat / 2)**2) + (Math.cos(lat1) * Math.cos(lat2) * (Math.sin(dlon / 2)**2))
      2 * EARTH_RADIUS_METERS * Math.asin(Math.sqrt(h))
    end

    # @return [Float] The initial bearing from a to b, in degrees from north.
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
