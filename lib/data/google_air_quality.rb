require 'httparty'
require 'active_support/all'

# The GoogleAirQuality class interfaces with the Google Air Quality API to fetch the AQI for a location.
class GoogleAirQuality
  attr_reader :aqi
  GOOGLE_AQI_API_URL = 'https://airquality.googleapis.com/v1'

  # Initializes the GoogleAirQuality class with geographical coordinates.
  # @param latitude [Float] The latitude for the location.
  # @param longitude [Float] The longitude for the location.
  # @param country_code [String] The country code for the location.
  # @param aqi_code [String] The code for the AQI to use (optional, defaults to EPA NowCast).
  # @param datetime [DateTime] Target datetime for forecast (optional, defaults to current conditions).
  # @return [GoogleAirQuality] The instance of the GoogleAirQuality class.
  def initialize(latitude, longitude, country_code, aqi_code = 'usa_epa_nowcast', datetime = nil)
    @latitude = latitude
    @longitude = longitude
    @country_code = country_code
    @aqi_code = aqi_code
    @datetime = datetime
    @aqi = get_aqi
  end

  # Saves the AQI data to a JSON file.
  def save_data
    File.open('data/air_quality.json', 'w') { |f| f << @aqi.to_json }
  end

  private

  # Gets the air quality data for the specified coordinates.
  # @return [Hash, nil] The AQI data, or nil if fetching fails.
  def get_aqi
    data = (@datetime.nil? || @datetime <= Time.current) ? get_current_conditions : get_forecast
    return if data.blank?

    if data[:hourlyForecasts].present?
      data = data[:hourlyForecasts].first
    end

    result = data[:indexes]&.find { |i| i[:code] == @aqi_code }
    result ||= data[:indexes]&.find { |i| i[:code] == 'uaqi' }

    return if result.blank?

    {
      aqi: result[:aqi],
      category: result[:category].gsub(/\s?air quality\s?/i, ' ').strip,
      description: result[:category]
    }
  end

  # Gets the AQI data for the given coordinates from the API.
  # @see https://developers.google.com/maps/documentation/air-quality/reference/rest/v1/currentConditions/lookup#http-request
  # @return [Hash, nil] AQI data, or nil if fetching fails.
  def get_current_conditions
    return if @latitude.blank? || @longitude.blank? || @country_code.blank?
    cache_key = "google:aqi:#{@latitude}:#{@longitude}:#{@country_code}:#{@aqi_code}"
    data = $redis.get(cache_key)

    return JSON.parse(data, symbolize_names: true) if data.present?

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

    $redis.setex(cache_key, 5.minutes, response.body)
    JSON.parse(response.body, symbolize_names: true)
  end

  # Gets the AQI forecast data for the given coordinates from the API.
  # @see https://developers.google.com/maps/documentation/air-quality/reference/rest/v1/forecast/lookup#http-request
  # @return [Array, nil] AQI forecast data array, or nil if fetching fails.
  def get_forecast
    return if @latitude.blank? || @longitude.blank? || @country_code.blank? || @datetime.blank?

    cache_key = "google:aqi:forecast:#{@latitude}:#{@longitude}:#{@country_code}:#{@aqi_code}:#{@datetime.iso8601}"
    data = $redis.get(cache_key)

    return JSON.parse(data, symbolize_names: true) if data.present?

    query = {
      key: ENV['GOOGLE_API_KEY']
    }

    body = {
      location: {
        latitude: @latitude,
        longitude: @longitude
      },
      dateTime: @datetime.iso8601,
      languageCode: 'en',
      extraComputations: ['LOCAL_AQI'],
      customLocalAqis: [{ regionCode: @country_code, aqi: @aqi_code }]
    }

    headers = {
      'Content-Type': 'application/json'
    }

    response = HTTParty.post("#{GOOGLE_AQI_API_URL}/forecast:lookup", query: query, body: body.to_json, headers: headers)
    return unless response.success?

    $redis.setex(cache_key, 5.minutes, response.body)
    JSON.parse(response.body, symbolize_names: true)
  end
end
