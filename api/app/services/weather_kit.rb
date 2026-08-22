require "jwt"
require "httparty"
require "openssl"
require "base64"

# Gets the weather from the Apple WeatherKit REST API. It authenticates with an ES256 JWT that it
# signs with the WEATHERKIT_* credentials. Redis caches the raw response for 5 minutes. `data`
# returns the weather in an object with dot access, or nil.
class WeatherKit < ApplicationService
  WEATHERKIT_API_URL = "https://weatherkit.apple.com/api/v1/"

  # ⚠️ This runs in the request of the weather widget, which has a 20s rack-timeout budget and
  # approximately ten upstream calls. The timeout for each call and the full budget are both much
  # smaller than the defaults of the app, on purpose. A chain of retries here with no limit — two
  # with_retries calls, one in the other, and 14s of waits in each one on the shared defaults —
  # uses the full request and gives the widget a 500. An empty fragment, where the edge serves its
  # stale-if-error copy, is faster and is what the live-update contract needs.
  HTTP_TIMEOUT = 4
  REQUEST_BUDGET = 8.0
  # One quick second attempt gets past a short problem and does not use much of the budget.
  RETRY_OPTIONS = { max: 1, base_delay: 0.25 }.freeze

  # @param latitude [Float]
  # @param longitude [Float]
  # @param time_zone [String] An IANA timezone id.
  # @param country [String] An ISO country code.
  def initialize(latitude, longitude, time_zone, country)
    @latitude = latitude
    @longitude = longitude
    @time_zone = time_zone
    @country = country
    @budget_expires_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + REQUEST_BUDGET
  end

  # @return [OpenStruct, nil] The weather data, with snake_case keys and dot access, or nil.
  def data
    fetch_wrapped { underscore_keys(get_weather) }
  end

  private

  # Gets the current weather data for the location. On a failure it waits, then tries again.
  # @see https://developer.apple.com/documentation/weatherkitrestapi
  # @return [Hash, nil]
  def get_weather
    return unless coordinates?
    return if @time_zone.blank? || @country.blank?

    cache_key = "weatherkit:weather:#{@latitude}:#{@longitude}:#{@time_zone}:#{@country}"
    cached_json(cache_key, expires_in: 5.minutes) do
      with_retries(**RETRY_OPTIONS, deadline: remaining_budget) do
        datasets = availability
        next if datasets.blank?

        query = {
          country: @country,
          dataSets: datasets.join(","),
          timezone: @time_zone
        }

        get_json!(
          "#{WEATHERKIT_API_URL}weather/en/#{@latitude}/#{@longitude}",
          query: query,
          headers: { "Authorization" => "Bearer #{token}" },
          timeout: HTTP_TIMEOUT
        )
      end
    end
  end

  # Finds the data sets that are available for the location. On a failure it waits, then tries
  # again.
  # @return [Array, nil]
  def availability
    cache_key = "weatherkit:availability:#{@latitude}:#{@longitude}:#{@time_zone}:#{@country}"
    cached_json(cache_key, expires_in: 5.minutes) do
      with_retries(**RETRY_OPTIONS, deadline: remaining_budget) do
        get_json!(
          "#{WEATHERKIT_API_URL}availability/#{@latitude}/#{@longitude}",
          query: { country: @country },
          headers: { "Authorization" => "Bearer #{token}" },
          timeout: HTTP_TIMEOUT
        )
      end
    end
  end

  # The time that stays in the budget of this instance. The two calls share it, thus a slow
  # availability lookup uses part of the time of the weather lookup, and the worst case is not two
  # times as long.
  # @return [Float]
  def remaining_budget
    [ @budget_expires_at - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0.0 ].max
  end

  # The ES256 JWT for the WeatherKit authentication. It is the same for the full app, because it
  # has no latitude and no longitude, and it is good for one minute. But a signature, which loads
  # the EC key and signs, is slow. Thus Redis holds it for a little less than its expiry time, and
  # each request and each instance uses the same one.
  # @return [String, nil]
  def token
    $redis.get("weatherkit:jwt") || generate_token
  end

  # Signs a new ES256 JWT and puts it in Redis for 50s. That is less than the 60s expiry time, and
  # the extra 10s is for a clock difference and for a request in progress. On a failure it returns
  # nil and puts nothing in the cache.
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
