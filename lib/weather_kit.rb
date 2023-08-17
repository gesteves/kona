require 'jwt'
require 'time'
require 'openssl'
require 'base64'
require 'httparty'

class WeatherKit
  WEATHERKIT_API_URL = 'https://weatherkit.apple.com/api/v1/'

  def initialize

  end

  def weather(latitude, longitude)
    headers = {
      "Authorization" => "Bearer #{token}"
    }

    query = {
      timezone: '-0600',
      dataSets: 'currentWeather,forecastDaily,weatherAlerts'
    }

    response = HTTParty.get("#{WEATHERKIT_API_URL}/weather/en/#{latitude}/#{longitude}", query: query, headers: headers)
    JSON.parse(response.body)
  end

  def save_data(latitude, longitude)
    File.open('data/weather.json','w'){ |f| f << weather(latitude, longitude).to_json }
  end

  private

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
