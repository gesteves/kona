require 'jwt'
require 'httparty'
require 'redis'
require 'active_support/all'

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
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
    @latitude = latitude
    @longitude = longitude
    @time_zone = time_zone
    @country = country
    @weather = get_weather
  end

  # Saves the current weather data to a JSON file.
  def save_data
    File.open('data/weather.json','w'){ |f| f << @weather.to_json }
  end

  private

  # Gets the current weather data for the specified location.
  # @see https://developer.apple.com/documentation/weatherkitrestapi/get_api_v1_weather_language_latitude_longitude
  # @return [Hash, nil] The current weather data, or nil if fetching fails.
  def get_weather
    cache_key = "weatherkit:weather:#{@latitude}:#{@longitude}:#{@time_zone}:#{@country}"
    data = @redis.get(cache_key)

    return JSON.parse(data) if data.present?

    datasets = availability
    return if datasets.blank?

    headers = {
      "Authorization" => "Bearer #{token}"
    }

    query = {
      countryCode: @country,
      dataSets: datasets&.join(','),
      timezone: @time_zone
    }

    response = HTTParty.get("#{WEATHERKIT_API_URL}/weather/en/#{@latitude}/#{@longitude}", query: query, headers: headers)
    return unless response.success?

    @redis.setex(cache_key, 5.minutes, response.body)
    JSON.parse(response.body)
  end

  # Checks the availability of weather data for the specified location.
  # @see https://developer.apple.com/documentation/weatherkitrestapi/get_api_v1_availability_latitude_longitude
  # @return [Array, nil] The available weather data sets, or nil if unavailable.
  def availability
    cache_key = "weatherkit:availability:#{@latitude}:#{@longitude}:#{@time_zone}:#{@country}"
    data = @redis.get(cache_key)

    return JSON.parse(data) if data.present?

    headers = {
      "Authorization" => "Bearer #{token}"
    }

    query = {
      country: @country
    }

    response = HTTParty.get("#{WEATHERKIT_API_URL}/availability/#{@latitude}/#{@longitude}", query: query, headers: headers)
    return unless response.success?

    @redis.setex(cache_key, 1.day, response.body)
    JSON.parse(response.body)
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

    current_time = Time.now.to_i

    claims = {
      iss: team_id,
      iat: current_time,
      exp: 1.minute.from_now.to_i,
      sub: service_id
    }

    private_key = OpenSSL::PKey::EC.new(private_key_content)

    JWT.encode(claims, private_key, 'ES256', header)
  end
end
