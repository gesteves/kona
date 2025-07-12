require 'httparty'
require 'active_support/all'

# The GoogleMaps class interfaces with the Google Maps API to fetch geocoding and timezone data.
class GoogleMaps
  attr_reader :latitude, :longitude, :location

  GOOGLE_MAPS_API_URL = 'https://maps.googleapis.com/maps/api'
  GOOGLE_API_KEY = ENV['GOOGLE_API_KEY']

  # Initializes the GoogleMaps class with geographical coordinates.
  # @param latitude [Float] The latitude for the location.
  # @param longitude [Float] The longitude for the location.
  # @return [GoogleMaps] The instance of the GoogleMaps class.
  def initialize(latitude, longitude)
    @latitude = latitude
    @longitude = longitude
    @location = {}
    @location[:geocoded] = reverse_geocode
    @location[:time_zone] = get_time_zone
    @location[:elevation] = get_elevation&.dig(:elevation)
  end

  # Returns a timezone ID of the form "America/Denver".
  # @return [String, nil] the timezone ID.
  def time_zone_id
    @location&.dig(:time_zone, :timeZoneId)
  end

  # Returns the country code for the specified coordinates.
  # @return [String, nil] The country code, or nil if fetching fails.
  def country_code
    @location&.dig(:geocoded, :address_components)&.find { |component| component[:types].include?('country') }&.dig(:short_name)
  end

  # Saves the geocode and time zone data to JSON files.
  def save_data
    File.open('data/location.json', 'w') { |f| f << @location&.deep_transform_keys { |key| key.to_s.underscore }.to_json }
  end

  private

  # Reverse-geocodes the given coordinates into a human-readable address.
  # @see https://developers.google.com/maps/documentation/geocoding/requests-reverse-geocoding
  # @return [Hash, nil] The geocoding data, or nil if fetching fails.
  def reverse_geocode
    return if @latitude.blank? || @longitude.blank?
    cache_key = "google:maps:geocoded:#{@latitude}:#{@longitude}"
    data = $redis.get(cache_key)

    return JSON.parse(data, symbolize_names: true) if data.present?

    query = {
      latlng: "#{@latitude},#{@longitude}",
      result_type: 'political',
      key: GOOGLE_API_KEY,
      language: 'en'
    }

    response = HTTParty.get("#{GOOGLE_MAPS_API_URL}/geocode/json", query: query)
    return unless response.success?

    data = JSON.parse(response.body, symbolize_names: true)&.dig(:results, 0)
    $redis.set(cache_key, data.to_json) if data.present?
    data
  end

  # Gets the elevation for the coordinates from the API.
  # @see https://developers.google.com/maps/documentation/elevation/requests-elevation#ElevationRequests
  # @return [Hash, nil] The elevation data, or nil if fetching fails.
  def get_elevation
    return if @latitude.blank? || @longitude.blank?
    cache_key = "google:maps:elevation:#{@latitude}:#{@longitude}"
    data = $redis.get(cache_key)

    return JSON.parse(data, symbolize_names: true) if data.present?

    query = {
      locations: "#{@latitude},#{@longitude}",
      key: GOOGLE_API_KEY
    }

    response = HTTParty.get("#{GOOGLE_MAPS_API_URL}/elevation/json", query: query)
    return unless response.success?

    data = JSON.parse(response.body, symbolize_names: true)&.dig(:results, 0)
    $redis.set(cache_key, data.to_json) if data.present?
    data
  end

  # Gets time zone data for the coordinates from the API.
  # @see https://developers.google.com/maps/documentation/timezone/requests-timezone
  # @return [Hash, nil] The time zone data, or nil if fetching fails.
  def get_time_zone
    return if @latitude.blank? || @longitude.blank?
    cache_key = "google:maps:time_zone:#{@latitude}:#{@longitude}"
    data = $redis.get(cache_key)

    return JSON.parse(data, symbolize_names: true) if data.present?

    query = {
      location: "#{@latitude},#{@longitude}",
      key: GOOGLE_API_KEY,
      timestamp: Time.now.to_i
    }

    response = HTTParty.get("#{GOOGLE_MAPS_API_URL}/timezone/json", query: query)
    return unless response.success?

    data = JSON.parse(response.body, symbolize_names: true)
    return unless data[:status] == 'OK'

    $redis.setex(cache_key, 1.hour, data.to_json)
    data
  end
end
