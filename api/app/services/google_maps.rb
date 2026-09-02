# Uses the Google Maps API to find the address of a pair of coordinates and to get their timezone
# and their elevation. The code does each lookup only when it is necessary and then keeps the
# result. Thus a request for the timezone alone does not start the geocode call and the elevation
# call. Redis caches each result for a day.
class GoogleMaps < ApplicationService
  include GoogleApi

  attr_reader :latitude, :longitude

  GOOGLE_MAPS_API_URL = "https://maps.googleapis.com/maps/api"

  # @param latitude [Float] The latitude of the location.
  # @param longitude [Float] The longitude of the location.
  def initialize(latitude, longitude)
    @latitude = latitude
    @longitude = longitude
  end

  # The full location hash: the address from the geocoder, the timezone, and the elevation. This
  # starts all three lookups.
  # @return [Hash]
  def location
    @location ||= { geocoded: geocoded, time_zone: time_zone, elevation: elevation }
  end

  # @return [Hash, nil] The address from the geocoder, with snake_case keys, or nil.
  def geocoded
    return @geocoded if defined?(@geocoded)
    @geocoded = underscore_keys(reverse_geocode)
  end

  # @return [Hash, nil] The timezone data, with snake_case keys, or nil.
  def time_zone
    return @time_zone if defined?(@time_zone)
    @time_zone = underscore_keys(get_time_zone)
  end

  # @return [Float, nil] The elevation in meters, or nil.
  def elevation
    return @elevation if defined?(@elevation)
    @elevation = get_elevation&.dig(:elevation)
  end

  # The timezone ID, in the form "America/Denver".
  # @return [String, nil] The timezone ID.
  def time_zone_id
    time_zone&.dig(:time_zone_id)
  end

  # The country code of the coordinates.
  # @return [String, nil] The country code, or nil if it is not available.
  def country_code
    geocoded&.dig(:address_components)&.find { |component| component[:types]&.include?("country") }&.dig(:short_name)
  end

  private

  # Changes the coordinates into an address that a person can read.
  # @see https://developers.google.com/maps/documentation/geocoding/requests-reverse-geocoding
  # @return [Hash, nil] The geocoder data, or nil if the fetch fails.
  def reverse_geocode
    return unless coordinates?

    cached_json("google:maps:geocoded:#{@latitude}:#{@longitude}", expires_in: 1.day) do
      query = {
        latlng: "#{@latitude},#{@longitude}",
        result_type: "political",
        key: google_api_key,
        language: "en"
      }
      get_json("#{GOOGLE_MAPS_API_URL}/geocode/json", query: query)&.dig(:results, 0)
    end
  end

  # Gets the elevation of the coordinates.
  # @see https://developers.google.com/maps/documentation/elevation/requests-elevation
  # @return [Hash, nil] The elevation data, or nil if the fetch fails.
  def get_elevation
    return unless coordinates?

    cached_json("google:maps:elevation:#{@latitude}:#{@longitude}", expires_in: 1.day) do
      query = {
        locations: "#{@latitude},#{@longitude}",
        key: google_api_key
      }
      get_json("#{GOOGLE_MAPS_API_URL}/elevation/json", query: query)&.dig(:results, 0)
    end
  end

  # Gets the timezone data of the coordinates.
  # @see https://developers.google.com/maps/documentation/timezone/requests-timezone
  # @return [Hash, nil] The timezone data, or nil if the fetch fails.
  def get_time_zone
    return unless coordinates?

    cached_json("google:maps:time_zone:#{@latitude}:#{@longitude}", expires_in: 1.day) do
      query = {
        location: "#{@latitude},#{@longitude}",
        key: google_api_key,
        timestamp: Time.now.to_i
      }
      data = get_json("#{GOOGLE_MAPS_API_URL}/timezone/json", query: query)
      data if data && data[:status] == "OK"
    end
  end
end
