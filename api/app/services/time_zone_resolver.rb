# Finds the IANA timezone id of a pair of coordinates. It uses Google Maps for the geocode. When
# there are no coordinates, and when the geocode is not available, it uses the default from the
# configuration: the TIME_ZONE env var, and then America/Denver.
class TimeZoneResolver
  DEFAULT_TIME_ZONE = "America/Denver"

  # The default timezone from the configuration. The code uses it when it cannot find the
  # coordinates.
  # @return [String] An IANA timezone id.
  def self.default
    ENV.fetch("TIME_ZONE", DEFAULT_TIME_ZONE)
  end

  # @param latitude [Float, nil]
  # @param longitude [Float, nil]
  # @return [String] An IANA timezone id. It is never nil: without one, it gives {default}.
  def self.call(latitude, longitude)
    return default if latitude.blank? || longitude.blank?

    GoogleMaps.new(latitude, longitude).time_zone_id || default
  end
end
