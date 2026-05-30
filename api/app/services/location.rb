# Represents the current geographic location used for timezone (and, later, weather,
# elevation, etc.) lookups. The location comes from the LOCATION env var if set and
# valid, otherwise from Redis, where it's written by the bearer-token-secured
# POST /location endpoint (shared with the web app).
class Location
  attr_reader :latitude, :longitude
  LOCATION_CACHE_KEY = "location:current"

  def initialize
    @latitude, @longitude = split_into_coordinates(current_location)
  end

  # Validates a latitude/longitude pair.
  # @return [Boolean] true if the coordinates are present and within range.
  def self.valid_coordinates?(latitude, longitude)
    return false if latitude.blank? || longitude.blank?
    return false if latitude < -90 || latitude > 90
    return false if longitude < -180 || longitude > 180
    true
  end

  private

  # Chooses the location to use, preferring the LOCATION env var and falling back to
  # the value cached in Redis.
  # @return [String, nil] The current location as a "latitude,longitude" string, if available.
  def current_location
    return ENV["LOCATION"] if split_into_coordinates(ENV["LOCATION"]).present?

    $redis.get(LOCATION_CACHE_KEY)
  end

  # Splits a "latitude,longitude" string into coordinates.
  # @param location [String] The location string.
  # @return [Array<Float>, nil] The latitude and longitude as floats, or nil if invalid.
  def split_into_coordinates(location)
    latitude, longitude = location&.split(",")&.map(&:to_f)
    return unless self.class.valid_coordinates?(latitude, longitude)

    [latitude, longitude]
  end
end
