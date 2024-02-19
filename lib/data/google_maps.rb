require 'httparty'
require 'redis'
require 'active_support/all'

# The GoogleMaps class interfaces with the Google Maps API to fetch geocoding and timezone data.
class GoogleMaps
  attr_reader :latitude, :longitude, :time_zone, :country_code, :elevation, :geocoded
  GOOGLE_MAPS_API_URL = 'https://maps.googleapis.com/maps/api'
  GOOGLE_API_KEY = ENV['GOOGLE_API_KEY']

  # Initializes the GoogleMaps class with geographical coordinates.
  # @param latitude [Float] The latitude for the location.
  # @param longitude [Float] The longitude for the location.
  # @return [GoogleMaps] The instance of the GoogleMaps class.
  def initialize(latitude, longitude)
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
    @latitude = latitude
    @longitude = longitude
    @geocoded = reverse_geocode
    @time_zone = get_time_zone
    @country_code = get_country_code
    @elevation = get_elevation
  end

  # Returns a timezone ID of the form "America/Denver".
  # @return [String, nil] the timezone ID.
  def time_zone_id
    return if @time_zone.blank?
    @time_zone['timeZoneId']
  end

  # Saves the geocode and time zone data to JSON files.
  def save_data
    File.open('data/location.json', 'w') { |f| f << @geocoded.to_json }
    File.open('data/time_zone.json', 'w') { |f| f << @time_zone.to_json }
    File.open('data/elevation.json', 'w') { |f| f << @elevation.to_json }
  end

  private

  # Gets the country code for the specified coordinates using geocoding.
  # @return [String, nil] The country code, or nil if fetching fails.
  def get_country_code
    data = @geocoded || reverse_geocode
    return if data.blank?
    data['address_components'].find { |component| component['types'].include?('country') }['short_name']
  end

  # Reverse-geocodes the given coordinates into a human-readable address.
  # @see https://developers.google.com/maps/documentation/geocoding/requests-reverse-geocoding
  # @return [Hash, nil] The geocoding data, or nil if fetching fails.
  def reverse_geocode
    return if @latitude.blank? || @longitude.blank?
    cache_key = "google_maps:geocoded:#{@latitude}:#{@longitude}"
    data = @redis.get(cache_key)

    return JSON.parse(data) if data.present?

    query = {
      latlng: "#{@latitude},#{@longitude}",
      key: GOOGLE_API_KEY,
      language: "en"
    }

    response = HTTParty.get("#{GOOGLE_MAPS_API_URL}/geocode/json", query: query)
    return unless response.success?

    data = JSON.parse(response.body)['results'][0]
    @redis.setex(cache_key, 1.day, data.to_json)
    data
  end

  # Gets the elevation for the coordinates from the API.
  # @see https://developers.google.com/maps/documentation/elevation/requests-elevation#ElevationRequests
  # @return [Hash, nil] The elevation data, or nil if fetching fails.
  def get_elevation
    return if @latitude.blank? || @longitude.blank?
    cache_key = "google_maps:elevation:#{@latitude}:#{@longitude}"
    data = @redis.get(cache_key)

    return JSON.parse(data) if data.present?

    query = {
      locations: "#{@latitude},#{@longitude}",
      key: GOOGLE_API_KEY
    }

    response = HTTParty.get("#{GOOGLE_MAPS_API_URL}/elevation/json", query: query)
    return unless response.success?

    data = JSON.parse(response.body)['results'][0]
    @redis.setex(cache_key, 1.day, data.to_json)
    data
  end

  # Gets time zone data for the coordinates from the API.
  # @see https://developers.google.com/maps/documentation/timezone/requests-timezone
  # @return [Hash, nil] The time zone data, or nil if fetching fails.
  def get_time_zone
    return if @latitude.blank? || @longitude.blank?
    cache_key = "google_maps:time_zone:#{@latitude}:#{@longitude}"
    data = @redis.get(cache_key)

    return JSON.parse(data) if data.present?

    query = {
      location: "#{@latitude},#{@longitude}",
      key: GOOGLE_API_KEY,
      timestamp: Time.now.to_i
    }

    response = HTTParty.get("#{GOOGLE_MAPS_API_URL}/timezone/json", query: query)
    return unless response.success?

    data = JSON.parse(response.body)
    data[:formattedOffset] = format_time_zone_offset(data['rawOffset'])
    @redis.setex(cache_key, 1.day, data.to_json)
    data
  end

  # Formats a time zone offset from seconds to a string format.
  # @param offset_in_seconds [Integer] The time zone offset in seconds.
  # @return [String] The formatted time zone offset.
  def format_time_zone_offset(offset_in_seconds)
    offset_minutes = offset_in_seconds.abs / 60
    hours = offset_minutes / 60
    minutes = offset_minutes % 60
    sign = offset_in_seconds < 0 ? "-" : "+"

    "#{sign}#{hours.to_s.rjust(2, '0')}#{minutes.to_s.rjust(2, '0')}"
  end
end
