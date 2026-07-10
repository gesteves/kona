require "httparty"
require "uri"

# Interacts with the Whoop API to fetch the most recent sleep, recovery, and strain
# data, and to run the OAuth2 flow that authorizes the app. Access and refresh tokens
# are stored in this app's Redis (the refresh token is the only durable credential —
# there's no DB) and the access token is refreshed as needed, handling refresh-token
# rotation.
class Whoop < ApplicationService
  WHOOP_API_URL = "https://api.prod.whoop.com/developer/v2"
  WHOOP_OAUTH_URL = "https://api.prod.whoop.com/oauth/oauth2"
  SCOPE = "offline read:recovery read:cycles read:workout read:sleep read:profile read:body_measurement"
  # How long a single token refresh may hold the serialization lock before it's presumed dead.
  REFRESH_LOCK_TTL = 30.seconds

  def initialize
    @client_id = ENV["WHOOP_CLIENT_ID"]
    @client_secret = ENV["WHOOP_CLIENT_SECRET"]
    @redirect_uri = ENV["WHOOP_REDIRECT_URI"]
  end

  # Returns the most recent scored cycle, sleep, and recovery for display.
  # @return [Hash, nil] A hash with :physiological_cycle, :sleep, and :recovery, or nil
  #   if any of the three is missing (in which case the widget renders nothing).
  def stats
    cycle = get_most_recent_scored_cycle
    sleep = get_sleep_for_cycle(cycle&.dig(:id))
    recovery = get_recovery_for_sleep(sleep&.dig(:id))

    return if cycle.blank? || sleep.blank? || recovery.blank?

    {
      physiological_cycle: cycle,
      sleep: sleep,
      recovery: recovery
    }
  end

  # Validates that the required OAuth environment variables are present.
  # @return [Boolean] true if all required variables are set.
  def valid_credentials?
    @client_id.present? && @client_secret.present? && @redirect_uri.present?
  end

  # The authenticated Whoop user's numeric id, used to verify webhook payloads belong to
  # the configured athlete. The id never changes, so it's cached for a day — the webhook
  # controller calls this in the request path and Whoop expects a 2xx within ~1s.
  # @return [Integer]
  # @raise [ApplicationService::HttpError] when the profile fetch fails.
  def user_id
    cached_json("whoop:#{@client_id}:user_id", expires_in: 1.day) do
      authed_get!("user/profile/basic")[:user_id]
    end
  end

  # Fetches a single workout by UUID.
  # @return [Hash, nil] A normalized workout hash (see #normalize_workout), or nil when the
  #   workout doesn't exist or isn't scored yet (PENDING_SCORE/UNSCORABLE carry no strain).
  def get_workout(uuid)
    workout = authed_get!("activity/workout/#{uuid}")
    return if workout[:score_state] != "SCORED" || workout[:score].nil?

    normalize_workout(workout)
  rescue ApplicationService::HttpError => e
    raise unless e.status == 404
    nil
  end

  # Fetches a single sleep by UUID. Named get_sleep (not `sleep`) so it can't shadow
  # Kernel#sleep, which wait_for_refreshed_token relies on.
  # @return [Hash, nil] The raw sleep hash, or nil when missing or not SCORED.
  def get_sleep(uuid)
    sleep_data = authed_get!("activity/sleep/#{uuid}")
    return if sleep_data[:score_state] != "SCORED"

    sleep_data
  rescue ApplicationService::HttpError => e
    raise unless e.status == 404
    nil
  end

  # Fetches the recovery scored against a cycle. Whoop v2 has no GET-by-recovery-id;
  # recoveries are keyed by their cycle.
  # @return [Hash, nil] The raw recovery hash, or nil when missing or not SCORED.
  def get_recovery_for_cycle(cycle_id)
    recovery = authed_get!("cycle/#{cycle_id}/recovery")
    return if recovery.nil? || recovery[:score_state] != "SCORED"

    recovery
  rescue ApplicationService::HttpError => e
    raise unless e.status == 404
    nil
  end

  # Fetches all cycles whose window may touch [start_ymd, end_ymd], following pagination.
  # The webhook's daily-strain refresh queries with a ±1-day buffer and buckets each cycle
  # by its end time in the athlete's timezone, so callers pass the buffered range here.
  # @param start_ymd [String] YYYY-MM-DD.
  # @param end_ymd [String] YYYY-MM-DD.
  # @return [Array<Hash>] Raw cycle hashes.
  # @raise [ApplicationService::HttpError] when any page fetch fails (retryable in a job).
  def raw_cycles(start_ymd, end_ymd)
    cycles = []
    next_token = nil

    loop do
      query = {
        start: "#{start_ymd}T00:00:00.000Z",
        end: "#{end_ymd}T23:59:59.999Z",
        limit: 25
      }
      query[:nextToken] = next_token if next_token.present?

      page = authed_get!("cycle", query)
      cycles.concat(Array(page[:records]))
      next_token = page[:next_token]
      break if next_token.blank?
    end

    cycles
  end

  # Builds the OAuth authorization URL for the given state.
  # @param state [String] An opaque value validated when Whoop redirects back.
  # @return [String, nil] The authorization URL, or nil if credentials are missing.
  def get_authorization_url(state)
    return unless valid_credentials?

    params = {
      client_id: @client_id,
      response_type: "code",
      scope: SCOPE,
      redirect_uri: @redirect_uri,
      state: state
    }

    "#{WHOOP_OAUTH_URL}/auth?" + URI.encode_www_form(params)
  end

  # Exchanges an authorization code for access and refresh tokens, storing them in Redis.
  # @param authorization_code [String] The authorization code from the OAuth callback.
  # @return [Hash, nil] Token data hash, or nil if the exchange failed.
  def exchange_code_for_tokens(authorization_code)
    return unless valid_credentials?

    params = {
      client_id: @client_id,
      client_secret: @client_secret,
      code: authorization_code,
      grant_type: "authorization_code",
      redirect_uri: @redirect_uri
    }

    response = HTTParty.post(
      "#{WHOOP_OAUTH_URL}/token",
      body: params,
      headers: { "Content-Type" => "application/x-www-form-urlencoded" }
    )

    return unless response.success?

    token_data = JSON.parse(response.body, symbolize_names: true)
    store_tokens(token_data)
    token_data
  rescue StandardError => e
    Rails.logger.error("Error exchanging Whoop authorization code: #{e}")
    report_upstream_error(e, context: "Whoop OAuth code exchange")
    nil
  end

  private

  # Maps Whoop sport_name values to the names ActivityMatcher's type map understands.
  # Whoop deprecated sport_id after 2025-09-01; sport_name is the stable field.
  SPORT_NAME_MAP = {
    "running" => "Running",
    "cycling" => "Cycling",
    "swimming" => "Swimming",
    "functional fitness" => "Functional Fitness",
    "hiit" => "HIIT",
    "skiing" => "Skiing",
    "rowing" => "Rowing",
    "weightlifting" => "Strength",
    "strength trainer" => "Strength"
  }.freeze

  # Normalizes a raw SCORED workout down to the fields the webhook flow uses. start_time is
  # kept as an instant; call sites render it as a local date in the athlete's timezone.
  # @param workout [Hash] The raw Whoop workout.
  # @return [Hash]
  def normalize_workout(workout)
    sport = SPORT_NAME_MAP[workout[:sport_name].to_s.downcase] || workout[:sport_name]

    {
      id: workout[:id].to_s,
      activity_type: ActivityMatcher.normalize_type(sport),
      start_time: Time.iso8601(workout[:start]),
      strain: workout.dig(:score, :strain)
    }
  end

  # GETs an authenticated Whoop API path, raising on failure (unlike the cached collection
  # fetchers, webhook processing wants exceptions so Sidekiq can retry).
  # @raise [RuntimeError] when no access token is available.
  # @raise [ApplicationService::HttpError] on a non-success response.
  def authed_get!(path, query = {})
    access_token = get_access_token
    raise "No Whoop access token available — visit /whoop/auth to authorize" if access_token.blank?

    get_json!(
      "#{WHOOP_API_URL}/#{path}",
      query: query,
      headers: { "Authorization" => "Bearer #{access_token}" }
    )
  end

  # Fetches the most recent scored cycle from the Whoop API.
  # @return [Hash, nil] The cycle data or nil if unavailable.
  def get_most_recent_scored_cycle
    cycles = get_cycles
    return if cycles.blank?

    cycles&.dig(:records)&.find { |cycle| cycle[:score_state] == "SCORED" }
  end

  # Fetches the most recent scored non-nap sleep data for a given cycle.
  # @param cycle_id [String] The ID of the cycle to fetch sleep data for.
  # @return [Hash, nil] The sleep data or nil if unavailable.
  def get_sleep_for_cycle(cycle_id)
    return if cycle_id.blank?

    sleeps = get_sleeps
    sleeps&.dig(:records)&.find { |sleep| sleep[:cycle_id] == cycle_id && sleep[:score_state] == "SCORED" && !sleep[:nap] }
  end

  # Fetches the most recent scored recovery data for a given sleep.
  # @param sleep_id [String] The ID of the sleep to fetch recovery data for.
  # @return [Hash, nil] The recovery data or nil if unavailable.
  def get_recovery_for_sleep(sleep_id)
    return if sleep_id.blank?

    recoveries = get_recoveries
    recoveries&.dig(:records)&.find { |recovery| recovery[:sleep_id] == sleep_id && recovery[:score_state] == "SCORED" }
  end

  # Fetches most recent sleep data from the Whoop API.
  # @see https://developer.whoop.com/api#tag/Sleep/operation/getSleepCollection
  # @return [Hash, nil] The full sleep data or nil if unavailable.
  def get_sleeps
    fetch_collection("activity/sleep", "sleeps", 5.minutes)
  end

  # Fetches most recent recovery data from the Whoop API.
  # @see https://developer.whoop.com/api#tag/Recovery/operation/getRecoveryCollection
  # @return [Hash, nil] The recovery data or nil if unavailable.
  def get_recoveries
    fetch_collection("recovery", "recoveries", 5.minutes)
  end

  # Fetches most recent cycle data from the Whoop API.
  # @see https://developer.whoop.com/api/#tag/Cycle/operation/getCycleCollection
  # @return [Hash, nil] The full cycle data or nil if unavailable.
  def get_cycles
    fetch_collection("cycle", "cycles", 1.minute)
  end

  # Fetches a Whoop collection endpoint, caching the raw response body in Redis.
  # @param path [String] The API path under WHOOP_API_URL.
  # @param cache_name [String] The suffix used in the Redis cache key.
  # @param ttl [ActiveSupport::Duration] How long to cache the response.
  # @return [Hash, nil] The parsed response, or nil if unavailable.
  def fetch_collection(path, cache_name, ttl)
    access_token = get_access_token
    return if access_token.blank?

    cached_json("whoop:#{@client_id}:#{cache_name}", expires_in: ttl) do
      get_json(
        "#{WHOOP_API_URL}/#{path}",
        headers: { "Authorization" => "Bearer #{access_token}" }
      )
    end
  end

  # Gets a valid access token, refreshing if necessary. Handles token rotation by
  # storing new refresh tokens when they're returned.
  # @see https://developer.whoop.com/docs/developing/oauth#access-token-expiration
  # @return [String, nil] Access token or nil if unable to refresh.
  def get_access_token
    return unless valid_credentials?

    cached_token = $redis.get(access_token_key)
    return cached_token if cached_token.present?

    refresh_access_token
  end

  # Refreshes the access token using the stored refresh token. Whoop rotates refresh tokens —
  # each refresh invalidates the token it was made with — so two concurrent refreshes race:
  # the loser POSTs an already-rotated token, gets rejected, and can wedge the integration
  # until a manual re-auth. A short Redis lock serializes refreshes; losers wait for the
  # winner's token instead of racing it, and the winner re-checks the cache inside the lock.
  # @return [String, nil] Access token or nil if unable to refresh.
  def refresh_access_token
    return wait_for_refreshed_token unless $redis.set(refresh_lock_key, "1", nx: true, ex: REFRESH_LOCK_TTL.to_i)

    begin
      # Another request may have finished refreshing between our cache miss and taking the lock.
      cached_token = $redis.get(access_token_key)
      return cached_token if cached_token.present?

      refresh_token = $redis.get(refresh_token_key)
      if refresh_token.blank?
        Rails.logger.warn("No Whoop refresh token found. Visit /whoop/auth to authorize.")
        return
      end

      refresh_params = {
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @client_id,
        "client_secret" => @client_secret,
        "scope" => SCOPE
      }

      response = HTTParty.post(
        "#{WHOOP_OAUTH_URL}/token",
        body: refresh_params,
        headers: { "Content-Type" => "application/x-www-form-urlencoded" }
      )

      unless response.success?
        Rails.logger.warn("Failed to refresh Whoop access token (HTTP #{response.code}). Visit /whoop/auth to re-authorize.")
        report_upstream_error("HTTP #{response.code}", context: "Whoop token refresh", status: response.code)
        return
      end

      token_data = JSON.parse(response.body, symbolize_names: true)
      store_tokens(token_data)
      token_data[:access_token]
    ensure
      $redis.del(refresh_lock_key)
    end
  rescue StandardError => e
    Rails.logger.error("Error refreshing Whoop token: #{e}")
    report_upstream_error(e, context: "Whoop token refresh")
    nil
  end

  # Briefly polls for the access token a concurrent refresh (the lock holder) is fetching.
  # @return [String, nil] The winner's access token, or nil if it doesn't appear in time.
  def wait_for_refreshed_token(attempts: 10, interval: 0.3)
    attempts.times do
      sleep(interval)
      token = $redis.get(access_token_key)
      return token if token.present?
    end

    Rails.logger.warn("Timed out waiting for a concurrent Whoop token refresh.")
    nil
  end

  # Stores access and refresh tokens in Redis.
  # @param token_data [Hash] Token response from the OAuth API.
  def store_tokens(token_data)
    access_token = token_data[:access_token]
    refresh_token = token_data[:refresh_token]
    expires_in = token_data[:expires_in].to_i

    # Store the access token with a 1-minute buffer before its actual expiry.
    access_cache_duration = [expires_in - 60, 0].max
    $redis.setex(access_token_key, access_cache_duration, access_token)

    # Store the refresh token without an expiry.
    $redis.set(refresh_token_key, refresh_token) if refresh_token.present?
  end

  def access_token_key
    "whoop:#{@client_id}:access_token"
  end

  def refresh_token_key
    "whoop:#{@client_id}:refresh_token"
  end

  def refresh_lock_key
    "whoop:#{@client_id}:refresh_lock"
  end
end
