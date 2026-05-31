# Resolves an IANA timezone id for a coordinate pair, geocoding via Google Maps and falling
# back to the configured default (TIME_ZONE env var, then America/Denver) when coordinates or
# geocoding are unavailable.
class TimeZoneResolver
  DEFAULT_TIME_ZONE = "America/Denver"

  # The configured fallback timezone, used when coordinates can't be resolved.
  # @return [String] An IANA timezone id.
  def self.default
    ENV.fetch("TIME_ZONE", DEFAULT_TIME_ZONE)
  end

  # @param latitude [Float, nil]
  # @param longitude [Float, nil]
  # @return [String] An IANA timezone id (never nil; falls back to {default}).
  def self.call(latitude, longitude)
    return default if latitude.blank? || longitude.blank?

    GoogleMaps.new(latitude, longitude).time_zone_id || default
  end
end
