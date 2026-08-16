# Represents the current geographic location used for timezone (and, later, weather,
# elevation, etc.) lookups. The location comes from the LOCATION env var if set and
# valid, otherwise from Redis, where it's written by the bearer-token-secured
# POST /location endpoint and by the admin's Location page.
class Location
  attr_reader :latitude, :longitude
  LOCATION_CACHE_KEY = "location:current"

  def initialize
    @latitude, @longitude = self.class.override || self.class.stored
  end

  # Validates a latitude/longitude pair.
  # @return [Boolean] true if the coordinates are present and within range.
  def self.valid_coordinates?(latitude, longitude)
    return false if latitude.blank? || longitude.blank?
    return false if latitude < -90 || latitude > 90
    return false if longitude < -180 || longitude > 180
    true
  end

  # Parses and validates a coordinate pair from any source — form fields, query parameters, or the
  # halves of a stored string.
  #
  # ⚠️ Parses with Float(), not to_f. to_f turns unparseable text into 0.0, which is a valid
  # coordinate — so a typo would silently resolve to Null Island instead of being rejected.
  # @return [Array(Float, Float), nil] The pair, or nil if either value is unusable.
  def self.parse(latitude, longitude)
    latitude = Float(latitude, exception: false)
    longitude = Float(longitude, exception: false)
    return unless valid_coordinates?(latitude, longitude)

    [ latitude, longitude ]
  end

  # Parses a "latitude,longitude" string.
  # @return [Array(Float, Float), nil]
  def self.parse_pair(location)
    latitude, longitude = location&.split(",")
    parse(latitude, longitude)
  end

  # The LOCATION env var, which outranks anything stored.
  # @return [Array(Float, Float), nil]
  def self.override
    parse_pair(ENV["LOCATION"])
  end

  # The stored location, ignoring the override.
  # @return [Array(Float, Float), nil]
  def self.stored
    parse_pair($redis.get(LOCATION_CACHE_KEY))
  end

  # Stores a coordinate pair as the current location and propagates it to Intervals.icu.
  #
  # ⚠️ Redis first, then the job. The stored value is what the widgets read, so it must not wait
  # on a geocoding hiccup; the sync is idempotent, so its Sidekiq retries are safe.
  # @param latitude [Float]
  # @param longitude [Float]
  def self.store(latitude, longitude)
    $redis.set(LOCATION_CACHE_KEY, "#{latitude},#{longitude}")
    LocationSyncJob.perform_async(latitude, longitude)
  end
end
