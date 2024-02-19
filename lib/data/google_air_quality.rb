require 'httparty'
require 'redis'
require 'active_support/all'

# The GoogleAirQuality class interfaces with the Google Air Quality API to fetch the AQI for a location.
class GoogleAirQuality
  GOOGLE_AQI_API_URL = 'https://airquality.googleapis.com/v1'

  # Initializes the GoogleAirQuality class with geographical coordinates.
  # @param latitude [Float] The latitude for the location.
  # @param longitude [Float] The longitude for the location.
  # @param country_code [String] The country code for the location.
  # @param aqi_code [String] The code for the AQI to use (optional, defaults to EPA NowCast).
  # @return [GoogleAirQuality] The instance of the GoogleAirQuality class.
  def initialize(latitude, longitude, country_code, aqi_code = 'usa_epa_nowcast')
    @latitude = latitude
    @longitude = longitude
    @country_code = country_code
    @aqi_code = aqi_code
    @aqi = set_aqi
  end

  # Saves the AQI data to a JSON file.
  def save_data
    File.open('data/air_quality.json', 'w') { |f| f << @aqi.to_json }
  end

  private

  # Sets the air quality data for the specified coordinates.
  # @return [Hash, nil] The AQI data, or nil if fetching fails.
  def set_aqi
    data = lookup_current_conditions
    return if data.blank?

    result = data['indexes']&.find { |i| i['code'] == @aqi_code }
    # Fall back to "Universal AQI"
    result ||= data['indexes']&.find { |i| i['code'] == 'uaqi' }

    return if result.blank?

    {
      aqi: result['aqi'],
      category: result['category'].gsub(/\s?air quality\s?/i, '')
    }
  end

  # gets the AQI data for the given coordinates from the API.
  # @see https://developers.google.com/maps/documentation/air-quality/reference/rest/v1/currentConditions/lookup#http-request
  # @return [Hash, nil] AQI data, or nil if fetching fails.
  def lookup_current_conditions
    return if @latitude.blank? || @longitude.blank? || @country_code.blank?
    cache_key = "google:aqi:#{@latitude}:#{@longitude}:#{@country_code}:#{@aqi_code}"
    data = $redis.get(cache_key)

    return JSON.parse(data) if data.present?

    query = {
      key: ENV['GOOGLE_API_KEY']
    }

    body = {
      location: {
        latitude: @latitude,
        longitude: @longitude
      },
      languageCode: 'en',
      extraComputations: ['LOCAL_AQI'],
      customLocalAqis: [{ regionCode: @country_code, aqi: @aqi_code }]
    }

    headers = {
      'Content-Type': 'application/json'
    }

    response = HTTParty.post("#{GOOGLE_AQI_API_URL}/currentConditions:lookup", query: query, body: body.to_json, headers: headers)
    return unless response.success?

    $redis.setex(cache_key, 1.hour, response.body)
    JSON.parse(response.body)
  end
end
