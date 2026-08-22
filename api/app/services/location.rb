# The current geographic location, for the timezone lookup and, later, for the weather, the
# elevation, and more. The location comes from the LOCATION env var, if that var has a correct
# value. In all other conditions it comes from Redis, where the POST /location endpoint, which needs
# a bearer token, and the Location page of the admin write it.
class Location
  attr_reader :latitude, :longitude
  LOCATION_CACHE_KEY = "location:current"

  def initialize
    @latitude, @longitude = self.class.override || self.class.stored
  end

  # Checks a latitude and longitude pair.
  # @return [Boolean] True if the two coordinates are available and in the correct range.
  def self.valid_coordinates?(latitude, longitude)
    return false if latitude.blank? || longitude.blank?
    return false if latitude < -90 || latitude > 90
    return false if longitude < -180 || longitude > 180
    true
  end

  # Parses and checks a pair of coordinates from each source: form fields, query parameters, or the
  # two parts of a stored string.
  #
  # ⚠️ It parses with Float(), and not with to_f. to_f changes text that it cannot parse into 0.0,
  # which is a correct coordinate. Thus a typing error would give the point at 0, 0 with no message,
  # and the code would not refuse it.
  # @return [Array(Float, Float), nil] The pair, or nil if one of the two values is incorrect.
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

  # The LOCATION env var, which replaces each stored value.
  # @return [Array(Float, Float), nil]
  def self.override
    parse_pair(ENV["LOCATION"])
  end

  # The stored location. This ignores the env var.
  # @return [Array(Float, Float), nil]
  def self.stored
    parse_pair($redis.get(LOCATION_CACHE_KEY))
  end

  # Stores a pair of coordinates as the current location and sends it to Intervals.icu.
  #
  # ⚠️ Write to Redis first, then add the job. The widgets read the stored value, thus it must not
  # wait for a problem in the geocoder. You can do the sync more than one time, thus its Sidekiq
  # retries are safe.
  # @param latitude [Float]
  # @param longitude [Float]
  def self.store(latitude, longitude)
    $redis.set(LOCATION_CACHE_KEY, "#{latitude},#{longitude}")
    LocationSyncJob.perform_async(latitude, longitude)
  end
end
