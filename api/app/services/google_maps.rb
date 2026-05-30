require "httparty"

# Interfaces with the Google Maps API to reverse-geocode coordinates and fetch their
# timezone and elevation. Responses are cached in Redis (timezone for a day, geocode
# and elevation indefinitely). Only the timezone is consumed for now.
class GoogleMaps
  attr_reader :latitude, :longitude, :location

  GOOGLE_MAPS_API_URL = "https://maps.googleapis.com/maps/api"

  # @param latitude [Float] The latitude for the location.
  # @param longitude [Float] The longitude for the location.
  def initialize(latitude, longitude)
    @latitude = latitude
    @longitude = longitude
    @location = {}
    @location[:geocoded] = reverse_geocode&.deep_transform_keys { |key| key.to_s.underscore.to_sym }
    @location[:time_zone] = get_time_zone&.deep_transform_keys { |key| key.to_s.underscore.to_sym }
    @location[:elevation] = get_elevation&.dig(:elevation)
  end

  # Returns a timezone ID of the form "America/Denver".
  # @return [String, nil] The timezone ID.
  def time_zone_id
    @location&.dig(:time_zone, :time_zone_id)
  end

  # Returns the country code for the coordinates.
  # @return [String, nil] The country code, or nil if unavailable.
  def country_code
    @location&.dig(:geocoded, :address_components)&.find { |component| component[:types].include?("country") }&.dig(:short_name)
  end

  private

  def api_key
    ENV["GOOGLE_API_KEY"]
  end

  # Reverse-geocodes the coordinates into a human-readable address.
  # @see https://developers.google.com/maps/documentation/geocoding/requests-reverse-geocoding
  # @return [Hash, nil] The geocoding data, or nil if fetching fails.
  def reverse_geocode
    return if @latitude.blank? || @longitude.blank?
    cache_key = "google:maps:geocoded:#{@latitude}:#{@longitude}"
    data = $redis.get(cache_key)

    return JSON.parse(data, symbolize_names: true) if data.present?

    query = {
      latlng: "#{@latitude},#{@longitude}",
      result_type: "political",
      key: api_key,
      language: "en"
    }

    response = HTTParty.get("#{GOOGLE_MAPS_API_URL}/geocode/json", query: query)
    return unless response.success?

    data = JSON.parse(response.body, symbolize_names: true)&.dig(:results, 0)
    $redis.set(cache_key, data.to_json) if data.present?
    data
  end

  # Gets the elevation for the coordinates.
  # @see https://developers.google.com/maps/documentation/elevation/requests-elevation
  # @return [Hash, nil] The elevation data, or nil if fetching fails.
  def get_elevation
    return if @latitude.blank? || @longitude.blank?
    cache_key = "google:maps:elevation:#{@latitude}:#{@longitude}"
    data = $redis.get(cache_key)

    return JSON.parse(data, symbolize_names: true) if data.present?

    query = {
      locations: "#{@latitude},#{@longitude}",
      key: api_key
    }

    response = HTTParty.get("#{GOOGLE_MAPS_API_URL}/elevation/json", query: query)
    return unless response.success?

    data = JSON.parse(response.body, symbolize_names: true)&.dig(:results, 0)
    $redis.set(cache_key, data.to_json) if data.present?
    data
  end

  # Gets timezone data for the coordinates.
  # @see https://developers.google.com/maps/documentation/timezone/requests-timezone
  # @return [Hash, nil] The timezone data, or nil if fetching fails.
  def get_time_zone
    return if @latitude.blank? || @longitude.blank?
    cache_key = "google:maps:time_zone:#{@latitude}:#{@longitude}"
    data = $redis.get(cache_key)

    return JSON.parse(data, symbolize_names: true) if data.present?

    query = {
      location: "#{@latitude},#{@longitude}",
      key: api_key,
      timestamp: Time.now.to_i
    }

    response = HTTParty.get("#{GOOGLE_MAPS_API_URL}/timezone/json", query: query)
    return unless response.success?

    data = JSON.parse(response.body, symbolize_names: true)
    return unless data[:status] == "OK"

    $redis.setex(cache_key, 1.day, data.to_json)
    data
  end
end
