require 'jwt'
require 'httparty'
require 'redis'

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
    cache_key = "weatherkit:weather:#{@latitude}:#{@longitude}"
    data = @redis.get(cache_key)

    return JSON.parse(data) unless data.nil?

    datasets = availability
    return if datasets.nil? || datasets.empty?

    headers = {
      "Authorization" => "Bearer #{token}"
    }

    query = {
      timezone: @time_zone,
      dataSets: datasets&.join(',')
    }

    response = HTTParty.get("#{WEATHERKIT_API_URL}/weather/en/#{@latitude}/#{@longitude}", query: query, headers: headers)
    return if response.code != 200

    @redis.setex(cache_key, 300, response.body)
    JSON.parse(response.body)
  end

  def save_data
    File.open('data/weather.json','w'){ |f| f << weather.to_json }
  end

  private

  def availability
    cache_key = "weatherkit:availability:#{@latitude}:#{@longitude}"
    data = @redis.get(cache_key)

    return JSON.parse(data) unless data.nil?

    headers = {
      "Authorization" => "Bearer #{token}"
    }

    query = {
      country: @country
    }

    response = HTTParty.get("#{WEATHERKIT_API_URL}/availability/#{@latitude}/#{@longitude}", query: query, headers: headers)
    return if response.code != 200

    @redis.setex(cache_key, 300, response.body)
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
      exp: current_time + 60,
      sub: service_id
    }

    private_key = OpenSSL::PKey::EC.new(private_key_content)

    JWT.encode(claims, private_key, 'ES256', header)
  end

end
