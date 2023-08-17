require 'jwt'
require 'httparty'
require 'redis'

class WeatherKit
  WEATHERKIT_API_URL = 'https://weatherkit.apple.com/api/v1/'

  def initialize
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
  end

  def weather(latitude, longitude, timezone = '-0600')
    datasets = availability(latitude, longitude)&.join(',')
    return unless datasets.nil? || datasets.empty?

    headers = {
      "Authorization" => "Bearer #{token}"
    }

    query = {
      timezone: timezone,
      dataSets: availability(latitude, longitude)&.join(',')
    }

    response = HTTParty.get("#{WEATHERKIT_API_URL}/weather/en/#{latitude}/#{longitude}", query: query, headers: headers)
    return unless response.code == 200
    JSON.parse(response.body)
  end

  def save_data(latitude, longitude)
    File.open('data/weather.json','w'){ |f| f << weather(latitude, longitude).to_json }
  end

  private

  def availability(latitude, longitude, country = 'US')
    headers = {
      "Authorization" => "Bearer #{token}"
    }

    query = {
      country: country
    }

    response = HTTParty.get("#{WEATHERKIT_API_URL}/availability/#{latitude}/#{longitude}", query: query, headers: headers)
    return unless response.code == 200
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
