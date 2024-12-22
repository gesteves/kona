require 'active_support/all'

# Represents a geographic location with latitude and longitude attributes.
class Location
  attr_reader :latitude, :longitude
  LOCATION_CACHE_KEY = 'location:current'

  # Initializes the Location instance by fetching the current location from available sources.
  def initialize
    @latitude, @longitude = split_into_coordinates(current_location)
  end

  private
  # Chooses the location to use for the various condition data (weather, pollen, air quality, etc.)
  # The location can come from a few places:
  # 1. From an environment variable, if present and valid.
  # 2. As coordinates in the payload of a Netlify build hook sent from my phone
  #    at regular intervals, which gets cached in redis.
  # 3. From that cache, if it's still there.
  # @return [String, nil] The current location as a "latitude,longitude" string, if available.
  def current_location
    return ENV['LOCATION'] if split_into_coordinates(ENV['LOCATION']).present?

    latitude, longitude = parse_incoming_hook_body
    if valid_coordinates?(latitude, longitude)
      location = "#{latitude},#{longitude}"
      $redis.set(LOCATION_CACHE_KEY, location)
      location
    else
      $redis.get(LOCATION_CACHE_KEY)
    end
  end

  # Validates the latitude and longitude values.
  # @param latitude [Float] Latitude value to be validated.
  # @param longitude [Float] Longitude value to be validated.
  # @return [Boolean] True if the coordinates are valid, otherwise false.
  def valid_coordinates?(latitude, longitude)
    return false if latitude.blank? || longitude.blank?
    return false if latitude < -90 || latitude > 90
    return false if longitude < -180 || longitude > 180
    true
  end

  # Splits a location string into latitude and longitude coordinates.
  # @param location [String] The location string in the format "latitude,longitude".
  # @return [Array<Float>, nil] An array containing the latitude and longitude as floats, or nil if invalid.
  def split_into_coordinates(location)
    latitude, longitude = location&.split(',')&.map(&:to_f)
    return if !valid_coordinates?(latitude, longitude)
    return latitude, longitude
  end

  # Parses the INCOMING_HOOK_BODY environment variable for latitude and longitude values.
  # @see https://docs.netlify.com/configure-builds/build-hooks/#payload
  # @return [Array, nil] An array of the `latitude` and `longitude` in the build hook payload, or nil.
  def parse_incoming_hook_body
    puts "Received incoming hook body: #{ENV['INCOMING_HOOK_BODY']}"
    payload = JSON.parse(ENV['INCOMING_HOOK_BODY'], symbolize_names: true)
    return payload[:latitude], payload[:longitude]
  rescue
    nil
  end
end
