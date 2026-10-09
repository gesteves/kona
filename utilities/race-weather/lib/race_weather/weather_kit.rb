require 'base64'
require 'httparty'
require 'jwt'
require 'openssl'

module RaceWeather
  # Gets the hourly history of one location from the Apple WeatherKit REST API. This follows
  # `WeatherKit#hourly` and `#generate_token` in the api, with no Redis.
  # @see https://developer.apple.com/documentation/weatherkitrestapi
  module WeatherKit
    extend self

    WEATHERKIT_API_URL = 'https://weatherkit.apple.com/api/v1'.freeze
    KEYS = %w[WEATHERKIT_KEY_ID WEATHERKIT_TEAM_ID WEATHERKIT_SERVICE_ID WEATHERKIT_PRIVATE_KEY].freeze
    HTTP_TIMEOUT = 15

    # @return [Boolean] True when each WeatherKit key has a value.
    def configured?
      KEYS.all? { |key| !ENV[key].to_s.empty? }
    end

    # @param lat [Float]
    # @param lng [Float]
    # @param from [Time] The first hour.
    # @param to [Time] The end of the range. WeatherKit does not include this hour.
    # @return [Array<Hash>] The hours, with the camelCase keys of WeatherKit and metric units. It is
    #   empty when WeatherKit has no data for the range.
    # @raise [RuntimeError] On an HTTP failure.
    def hourly(lat, lng, from:, to:)
      response = HTTParty.get(
        "#{WEATHERKIT_API_URL}/weather/en/#{lat}/#{lng}",
        query: { dataSets: 'forecastHourly', hourlyStart: from.utc.iso8601, hourlyEnd: to.utc.iso8601 },
        headers: { 'Authorization' => "Bearer #{token}" },
        timeout: HTTP_TIMEOUT
      )
      raise "WeatherKit returned status #{response.code}" unless response.success?

      body = response.parsed_response
      body.is_a?(Hash) ? Array(body.dig('forecastHourly', 'hours')) : []
    end

    private

    # An ES256 JWT, good for one hour. One run makes one token.
    # @see https://developer.apple.com/documentation/weatherkitrestapi/request_authentication_for_weatherkit_rest_api
    def token
      @token ||= begin
        team_id = ENV.fetch('WEATHERKIT_TEAM_ID')
        service_id = ENV.fetch('WEATHERKIT_SERVICE_ID')
        header = { alg: 'ES256', kid: ENV.fetch('WEATHERKIT_KEY_ID'), id: "#{team_id}.#{service_id}" }
        now = Time.now.to_i
        claims = { iss: team_id, iat: now, exp: now + 3600, sub: service_id }
        key = OpenSSL::PKey::EC.new(Base64.decode64(ENV.fetch('WEATHERKIT_PRIVATE_KEY')))
        JWT.encode(claims, key, 'ES256', header)
      end
    end
  end
end
