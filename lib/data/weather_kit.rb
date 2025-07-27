require 'jwt'
require 'httparty'
require 'active_support/all'
require 'openssl'
require 'base64'

# The WeatherKit class interfaces with Apple's WeatherKit API to fetch weather data.
class WeatherKit
  attr_reader :weather
  WEATHERKIT_API_URL = 'https://weatherkit.apple.com/api/v1/'

  # Initializes the WeatherKit class with location and time zone information.
  # @param latitude [Float] The latitude for the weather data.
  # @param longitude [Float] The longitude for the weather data.
  # @param time_zone [String] The time zone for the weather data.
  # @param country [String] The country for the weather data.
  # @return [WeatherKit] The instance of the WeatherKit class.
  def initialize(latitude, longitude, time_zone, country)
    @latitude = latitude
    @longitude = longitude
    @time_zone = time_zone
    @country = country
    @weather = get_weather&.deep_transform_keys { |key| key.to_s.underscore.to_sym }
  end

  # Saves the current weather data to a JSON file.
  def save_data
    File.open('data/weather.json','w'){ |f| f << @weather.to_json }
  end

  private

  # Gets the current weather data for the specified location.
  # Retries up to three times with an exponential backoff if fetching fails.
  # @see https://developer.apple.com/documentation/weatherkitrestapi/get_api_v1_weather_language_latitude_longitude
  # @return [Hash, nil] The current weather data, or nil if fetching fails.
  def get_weather
    return if @latitude.blank? || @longitude.blank? || @time_zone.blank? || @country.blank?

    retries ||= 0
    cache_key = "weatherkit:weather:#{@latitude}:#{@longitude}:#{@time_zone}:#{@country}"
    data = $redis.get(cache_key)

    return JSON.parse(data, symbolize_names: true) if data.present?

    datasets = availability
    return if datasets.blank?

    headers = {
      "Authorization" => "Bearer #{token}"
    }

    query = {
      country: @country,
      dataSets: datasets&.join(','),
      timezone: @time_zone
    }

    response = HTTParty.get("#{WEATHERKIT_API_URL}weather/en/#{@latitude}/#{@longitude}", query: query, headers: headers)
    raise "Failed to fetch weather data: #{response.code}" unless response.success?

    $redis.setex(cache_key, 5.minutes, response.body)
    JSON.parse(response.body, symbolize_names: true)

  rescue StandardError
    retries += 1
    if retries <= 3
      sleep(2**retries)
      retry
    end
    nil
  end

  # Checks the availability of weather data for the specified location.
  # Retries up to three times with an exponential backoff if fetching fails.
  # @see https://developer.apple.com/documentation/weatherkitrestapi/get_api_v1_availability_latitude_longitude
  # @return [Array, nil] The available weather data sets, or nil if unavailable.
  def availability
    retries ||= 0
    cache_key = "weatherkit:availability:#{@latitude}:#{@longitude}:#{@time_zone}:#{@country}"
    data = $redis.get(cache_key)

    return JSON.parse(data, symbolize_names: true) if data.present?

    headers = {
      "Authorization" => "Bearer #{token}"
    }

    query = {
      country: @country
    }

    response = HTTParty.get("#{WEATHERKIT_API_URL}availability/#{@latitude}/#{@longitude}", query: query, headers: headers)
    raise "Failed to fetch availability data: #{response.code}" unless response.success?

    $redis.setex(cache_key, 5.minutes, response.body)
    JSON.parse(response.body, symbolize_names: true)

  rescue StandardError
    retries += 1
    if retries <= 3
      sleep(2**retries)
      retry
    end
    nil
  end

  # Generates an authentication token for the WeatherKit API.
  # @see https://developer.apple.com/documentation/weatherkitrestapi/request_authentication_for_weatherkit_rest_api
  # @return [String] The generated JWT authentication token.
  def token
    key_id = ENV['WEATHERKIT_KEY_ID']
    team_id = ENV['WEATHERKIT_TEAM_ID']
    service_id = ENV['WEATHERKIT_SERVICE_ID']
    private_key_content = Base64.decode64(ENV['WEATHERKIT_PRIVATE_KEY'])

    header = {
      alg: 'ES256',
      kid: key_id,
      id: "#{team_id}.#{service_id}"
    }

    claims = {
      iss: team_id,
      iat: Time.now.to_i,
      exp: 1.minute.from_now.to_i,
      sub: service_id
    }

    private_key = OpenSSL::PKey::EC.new(private_key_content)

    JWT.encode(claims, private_key, 'ES256', header)
  rescue
    nil
  end
end
