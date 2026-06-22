require "jwt"
require "httparty"
require "openssl"
require "base64"

# Fetches weather from Apple's WeatherKit REST API. Authenticates with an ES256 JWT
# signed from the WEATHERKIT_* credentials. The raw response is cached in Redis for
# 5 minutes. `data` returns the weather wrapped for dot-access (or nil).
class WeatherKit < ApplicationService
  WEATHERKIT_API_URL = "https://weatherkit.apple.com/api/v1/"

  # @param latitude [Float]
  # @param longitude [Float]
  # @param time_zone [String] IANA timezone id
  # @param country [String] ISO country code
  def initialize(latitude, longitude, time_zone, country)
    @latitude = latitude
    @longitude = longitude
    @time_zone = time_zone
    @country = country
  end

  # @return [OpenStruct, nil] The weather data (snake_cased, dot-accessible), or nil.
  def data
    return @data if defined?(@data)
    weather = underscore_keys(get_weather)
    @data = weather && DeepOstruct.wrap(weather)
  end

  private

  # Gets the current weather data for the location, retrying with backoff on failure.
  # @see https://developer.apple.com/documentation/weatherkitrestapi
  # @return [Hash, nil]
  def get_weather
    return if @latitude.blank? || @longitude.blank? || @time_zone.blank? || @country.blank?

    cache_key = "weatherkit:weather:#{@latitude}:#{@longitude}:#{@time_zone}:#{@country}"
    cached_json(cache_key, expires_in: 5.minutes) do
      with_retries do
        datasets = availability
        next if datasets.blank?

        query = {
          country: @country,
          dataSets: datasets.join(","),
          timezone: @time_zone
        }

        response = HTTParty.get(
          "#{WEATHERKIT_API_URL}weather/en/#{@latitude}/#{@longitude}",
          query: query,
          headers: { "Authorization" => "Bearer #{token}" }
        )
        raise "Failed to fetch weather data: #{response.code}" unless response.success?

        JSON.parse(response.body, symbolize_names: true)
      end
    end
  end

  # Checks which datasets are available for the location, retrying with backoff on failure.
  # @return [Array, nil]
  def availability
    cache_key = "weatherkit:availability:#{@latitude}:#{@longitude}:#{@time_zone}:#{@country}"
    cached_json(cache_key, expires_in: 5.minutes) do
      with_retries do
        response = HTTParty.get(
          "#{WEATHERKIT_API_URL}availability/#{@latitude}/#{@longitude}",
          query: { country: @country },
          headers: { "Authorization" => "Bearer #{token}" }
        )
        raise "Failed to fetch availability data: #{response.code}" unless response.success?

        JSON.parse(response.body, symbolize_names: true)
      end
    end
  end

  # The ES256 JWT used to authenticate with WeatherKit. It's app-global (no lat/lon) and valid
  # for one minute, but signing it (EC key load + sign) is relatively expensive, so cache it in
  # Redis just under its expiry and reuse it across requests/instances.
  # @return [String, nil]
  def token
    $redis.get("weatherkit:jwt") || generate_token
  end

  # Signs a fresh ES256 JWT and caches it in Redis for 50s (< the 60s exp, leaving a buffer for
  # clock skew and in-flight requests). Returns nil without caching on failure.
  # @see https://developer.apple.com/documentation/weatherkitrestapi/request_authentication_for_weatherkit_rest_api
  # @return [String, nil]
  def generate_token
    key_id = ENV["WEATHERKIT_KEY_ID"]
    team_id = ENV["WEATHERKIT_TEAM_ID"]
    service_id = ENV["WEATHERKIT_SERVICE_ID"]
    private_key_content = Base64.decode64(ENV["WEATHERKIT_PRIVATE_KEY"].to_s)

    header = {
      alg: "ES256",
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
    jwt = JWT.encode(claims, private_key, "ES256", header)
    $redis.setex("weatherkit:jwt", 50, jwt)
    jwt
  rescue StandardError => e
    report_upstream_error(e, context: "WeatherKit JWT generation")
    nil
  end
end
