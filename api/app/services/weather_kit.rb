require "jwt"
require "httparty"
require "openssl"
require "base64"

# Fetches weather from Apple's WeatherKit REST API. Authenticates with an ES256 JWT
# signed from the WEATHERKIT_* credentials. The raw response is cached in Redis for
# 5 minutes. `data` returns the weather wrapped for dot-access (or nil).
class WeatherKit
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
    weather = get_weather&.deep_transform_keys { |key| key.to_s.underscore.to_sym }
    @data = weather && DeepOstruct.wrap(weather)
  end

  private

  # Gets the current weather data for the location, retrying with backoff on failure.
  # @see https://developer.apple.com/documentation/weatherkitrestapi
  # @return [Hash, nil]
  def get_weather
    return if @latitude.blank? || @longitude.blank? || @time_zone.blank? || @country.blank?

    retries ||= 0
    cache_key = "weatherkit:weather:#{@latitude}:#{@longitude}:#{@time_zone}:#{@country}"
    cached = $redis.get(cache_key)
    return JSON.parse(cached, symbolize_names: true) if cached.present?

    datasets = availability
    return if datasets.blank?

    query = {
      country: @country,
      dataSets: datasets&.join(","),
      timezone: @time_zone
    }

    response = HTTParty.get(
      "#{WEATHERKIT_API_URL}weather/en/#{@latitude}/#{@longitude}",
      query: query,
      headers: { "Authorization" => "Bearer #{token}" }
    )
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

  # Checks which datasets are available for the location, retrying with backoff on failure.
  # @return [Array, nil]
  def availability
    retries ||= 0
    cache_key = "weatherkit:availability:#{@latitude}:#{@longitude}:#{@time_zone}:#{@country}"
    cached = $redis.get(cache_key)
    return JSON.parse(cached, symbolize_names: true) if cached.present?

    response = HTTParty.get(
      "#{WEATHERKIT_API_URL}availability/#{@latitude}/#{@longitude}",
      query: { country: @country },
      headers: { "Authorization" => "Bearer #{token}" }
    )
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

  # Generates the ES256 JWT used to authenticate with WeatherKit.
  # @see https://developer.apple.com/documentation/weatherkitrestapi/request_authentication_for_weatherkit_rest_api
  # @return [String, nil]
  def token
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
    JWT.encode(claims, private_key, "ES256", header)
  rescue StandardError
    nil
  end
end
