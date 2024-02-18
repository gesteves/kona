require 'httparty'
require 'redis'
require 'active_support/all'

# The GoogleAirQuality class interfaces with the Google Air Quality API to fetch the AQI for a location.
class GoogleAirQuality
  GOOGLE_AQI_API_URL = 'https://airquality.googleapis.com/v1'

  # Initializes the GoogleAirQuality class with geographical coordinates.
  # @param latitude [Float] The latitude for the location.
  # @param longitude [Float] The longitude for the location.
  # @param longitude [String] The country code for the location (optional, defaults to US).
  # @return [GoogleAirQuality] The instance of the GoogleAirQuality class.
  def initialize(latitude, longitude, country_code = 'US')
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
    @latitude = latitude
    @longitude = longitude
    @country_code = country_code
  end

  # Retrieves the air quality data for the specified coordinates.
  # @return [Hash, nil] The AQI data, or nil if fetching fails.
  def aqi
    data = current_conditions
    return if data.blank? || data['indexes'].blank?

    result = data['indexes'][0]

    {
      aqi: result['aqi'],
      category: result['category'].gsub(/\s?air quality\s?/i, '')
    }

  end

  # Saves the AQI data to a JSON file.
  def save_data
    File.open('data/air_quality.json', 'w') { |f| f << aqi.to_json }
  end

  private

  # Returns the AQI data for the given coordinates.
  # @see https://developers.google.com/maps/documentation/air-quality/reference/rest/v1/currentConditions/lookup#http-request
  # @return [Hash, nil] AQI data, or nil if fetching fails.
  def current_conditions
    return if @latitude.blank? || @longitude.blank?
    cache_key = "google:aqi:#{@latitude}:#{@longitude}"
    data = @redis.get(cache_key)

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
      universalAqi: false,
      extraComputations: ['LOCAL_AQI'],
      customLocalAqis: [{ regionCode: @country_code, aqi: 'usa_epa_nowcast' }]
    }

    headers = {
      'Content-Type': 'application/json'
    }

    response = HTTParty.post("#{GOOGLE_AQI_API_URL}/currentConditions:lookup", query: query, body: body.to_json, headers: headers)
    return unless response.success?

    @redis.setex(cache_key, 1.hour, response.body)
    JSON.parse(response.body)
  end
end
