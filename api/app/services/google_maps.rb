# Interfaces with the Google Maps API to reverse-geocode coordinates and fetch their
# timezone and elevation. Each lookup is fetched lazily and memoized — asking only for the
# timezone won't trigger the geocode/elevation calls — and cached in Redis (timezone for a
# day, geocode and elevation indefinitely).
class GoogleMaps < ApplicationService
  attr_reader :latitude, :longitude

  GOOGLE_MAPS_API_URL = "https://maps.googleapis.com/maps/api"

  # @param latitude [Float] The latitude for the location.
  # @param longitude [Float] The longitude for the location.
  def initialize(latitude, longitude)
    @latitude = latitude
    @longitude = longitude
  end

  # The assembled location hash (geocoded address, timezone, elevation). Triggers all three
  # lookups.
  # @return [Hash]
  def location
    @location ||= { geocoded: geocoded, time_zone: time_zone, elevation: elevation }
  end

  # @return [Hash, nil] The reverse-geocoded address (snake_cased keys), or nil.
  def geocoded
    return @geocoded if defined?(@geocoded)
    @geocoded = underscore_keys(reverse_geocode)
  end

  # @return [Hash, nil] The timezone data (snake_cased keys), or nil.
  def time_zone
    return @time_zone if defined?(@time_zone)
    @time_zone = underscore_keys(get_time_zone)
  end

  # @return [Float, nil] The elevation in meters, or nil.
  def elevation
    return @elevation if defined?(@elevation)
    @elevation = get_elevation&.dig(:elevation)
  end

  # Returns a timezone ID of the form "America/Denver".
  # @return [String, nil] The timezone ID.
  def time_zone_id
    time_zone&.dig(:time_zone_id)
  end

  # Returns the country code for the coordinates.
  # @return [String, nil] The country code, or nil if unavailable.
  def country_code
    geocoded&.dig(:address_components)&.find { |component| component[:types].include?("country") }&.dig(:short_name)
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

    cached_json("google:maps:geocoded:#{@latitude}:#{@longitude}", expires_in: 1.day) do
      query = {
        latlng: "#{@latitude},#{@longitude}",
        result_type: "political",
        key: api_key,
        language: "en"
      }
      get_json("#{GOOGLE_MAPS_API_URL}/geocode/json", query: query)&.dig(:results, 0)
    end
  end

  # Gets the elevation for the coordinates.
  # @see https://developers.google.com/maps/documentation/elevation/requests-elevation
  # @return [Hash, nil] The elevation data, or nil if fetching fails.
  def get_elevation
    return if @latitude.blank? || @longitude.blank?

    cached_json("google:maps:elevation:#{@latitude}:#{@longitude}", expires_in: 1.day) do
      query = {
        locations: "#{@latitude},#{@longitude}",
        key: api_key
      }
      get_json("#{GOOGLE_MAPS_API_URL}/elevation/json", query: query)&.dig(:results, 0)
    end
  end

  # Gets timezone data for the coordinates.
  # @see https://developers.google.com/maps/documentation/timezone/requests-timezone
  # @return [Hash, nil] The timezone data, or nil if fetching fails.
  def get_time_zone
    return if @latitude.blank? || @longitude.blank?

    cached_json("google:maps:time_zone:#{@latitude}:#{@longitude}", expires_in: 1.day) do
      query = {
        location: "#{@latitude},#{@longitude}",
        key: api_key,
        timestamp: Time.now.to_i
      }
      data = get_json("#{GOOGLE_MAPS_API_URL}/timezone/json", query: query)
      data if data && data[:status] == "OK"
    end
  end
end
