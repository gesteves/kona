require 'jwt'
require 'httparty'
require 'redis'
require 'active_support/all'

class WeatherKit
  WEATHERKIT_API_URL = 'https://weatherkit.apple.com/api/v1/'

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
  end

  def weather
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

  def save_data
    File.open('data/weather.json','w'){ |f| f << weather.to_json }
  end

  private

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
