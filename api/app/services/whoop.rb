require "httparty"
require "uri"

# Fetches sleep, recovery, and strain data from the Whoop API, and runs the OAuth2 flow that
# authorizes the app. Tokens live in Redis — there's no DB, so the refresh token is the only
# durable credential — and the access token is refreshed on demand, handling rotation.
class Whoop < ApplicationService
  include ParallelUpstreams

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

  # @return [Hash, nil] The most recent scored :physiological_cycle, :sleep, and :recovery, or
  #   nil if any is missing, in which case the widget renders nothing.
  def stats
    # Only the *filtering* below chains (a sleep is matched to a cycle, a recovery to a sleep) —
    # the three collection fetches themselves are independent, so they run concurrently rather
    # than as three serial round trips on a cold cache.
    collections = in_parallel(
      cycles: -> { rescue_with(context: "Whoop cycles") { get_cycles } },
      sleeps: -> { rescue_with(context: "Whoop sleeps") { get_sleeps } },
      recoveries: -> { rescue_with(context: "Whoop recoveries") { get_recoveries } }
    )

    cycle = most_recent_scored_cycle(collections[:cycles])
    sleep = sleep_for_cycle(collections[:sleeps], cycle&.dig(:id))
    recovery = recovery_for_sleep(collections[:recoveries], sleep&.dig(:id))

    return if cycle.blank? || sleep.blank? || recovery.blank?

    # ⚠️ A record can be SCORED and still be missing the one sub-score the widget renders. The
    # presenter rounds all three unconditionally, and by then the controller's render_empty is
    # already behind us — so the check belongs here, where "no data" is still expressible.
    return if cycle.dig(:score, :strain).nil? ||
              sleep.dig(:score, :sleep_performance_percentage).nil? ||
              recovery.dig(:score, :recovery_score).nil?

    {
      physiological_cycle: cycle,
      sleep: sleep,
      recovery: recovery
    }
  end

  # @return [Boolean] Whether the OAuth credentials are configured.
  def valid_credentials?
    @client_id.present? && @client_secret.present? && @redirect_uri.present?
  end

  # The authenticated user's numeric id, for verifying that webhook payloads belong to the
  # configured athlete. Cached for a day, since the webhook controller calls this in the
  # request path and Whoop expects a 2xx within about a second.
  # @return [Integer]
  # @raise [ApplicationService::HttpError] when the profile fetch fails.
  def user_id
    cached_json("whoop:#{@client_id}:user_id", expires_in: 1.day) do
      authed_get!("user/profile/basic")[:user_id]
    end
  end

  # Fetches one workout by UUID.
  # @return [Hash, nil] The normalized workout, or nil when it's missing or unscored — an
  #   unscored workout carries no strain.
  def get_workout(uuid)
    workout = authed_get_or_nil("activity/workout/#{uuid}")
    return if workout.nil? || workout[:score_state] != "SCORED" || workout[:score].nil?

    normalize_workout(workout)
  end

  # Fetches one sleep by UUID. Named get_sleep so it can't shadow Kernel#sleep, which
  # wait_for_refreshed_token relies on.
  # @return [Hash, nil] The raw sleep, or nil when missing or unscored.
  def get_sleep(uuid)
    sleep_data = authed_get_or_nil("activity/sleep/#{uuid}")
    return if sleep_data.nil? || sleep_data[:score_state] != "SCORED"

    sleep_data
  end

  # Fetches the recovery scored against a cycle. Whoop v2 has no GET-by-recovery-id — they're
  # keyed by cycle.
  # @return [Hash, nil] The raw recovery, or nil when missing or unscored.
  def get_recovery_for_cycle(cycle_id)
    recovery = authed_get_or_nil("cycle/#{cycle_id}/recovery")
    return if recovery.nil? || recovery[:score_state] != "SCORED"

    recovery
  end

  # Fetches every cycle whose window may touch the given range, following pagination. Callers
  # pass a buffered range, since a cycle is bucketed by its end time in the athlete's timezone.
  # @param start_ymd [String] The start date, as YYYY-MM-DD.
  # @param end_ymd [String] The end date, as YYYY-MM-DD.
  # @return [Array<Hash>] Raw cycles.
  # @raise [ApplicationService::HttpError] when any page fails, so the job retries.
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

  # @param state [String] An opaque value validated when Whoop redirects back.
  # @return [String, nil] The OAuth authorization URL, or nil without credentials.
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

  # Exchanges an authorization code for tokens and stores them in Redis.
  # @param authorization_code [String] The code from the OAuth callback.
  # @return [Hash, nil] The token data, or nil if the exchange failed.
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

  # Maps Whoop sport_name values onto the names ActivityMatcher's type map understands.
  # sport_name is the stable field — sport_id was deprecated after 2025-09-01.
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

  # Normalizes a scored workout to the fields the webhook flow uses. start_time stays an
  # instant; call sites render it in the athlete's timezone.
  # @param workout [Hash] The raw workout.
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

  # GETs an authenticated API path, raising on failure so Sidekiq can retry — unlike the
  # cached collection fetchers, which degrade.
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

  # Like authed_get!, but treats a 404 as a clean skip. Any other error still propagates so
  # Sidekiq can retry.
  def authed_get_or_nil(path)
    authed_get!(path)
  rescue ApplicationService::HttpError => e
    raise unless e.status == 404
    nil
  end

  # @return [Hash, nil] The most recent scored cycle, or nil when unavailable.
  # @param cycles [Hash, nil] The cycle collection.
  # @return [Hash, nil] The most recent scored cycle, or nil when unavailable.
  def most_recent_scored_cycle(cycles)
    cycles&.dig(:records)&.find { |cycle| cycle[:score_state] == "SCORED" }
  end

  # @param sleeps [Hash, nil] The sleep collection.
  # @param cycle_id [String, nil] The cycle's id.
  # @return [Hash, nil] Its most recent scored non-nap sleep, or nil when unavailable.
  def sleep_for_cycle(sleeps, cycle_id)
    return if cycle_id.blank?

    sleeps&.dig(:records)&.find { |sleep| sleep[:cycle_id] == cycle_id && sleep[:score_state] == "SCORED" && !sleep[:nap] }
  end

  # @param recoveries [Hash, nil] The recovery collection.
  # @param sleep_id [String, nil] The sleep's id.
  # @return [Hash, nil] Its most recent scored recovery, or nil when unavailable.
  def recovery_for_sleep(recoveries, sleep_id)
    return if sleep_id.blank?

    recoveries&.dig(:records)&.find { |recovery| recovery[:sleep_id] == sleep_id && recovery[:score_state] == "SCORED" }
  end

  # @see https://developer.whoop.com/api#tag/Sleep/operation/getSleepCollection
  # @return [Hash, nil] The recent sleep collection, or nil when unavailable.
  def get_sleeps
    fetch_collection("activity/sleep", "sleeps", 5.minutes)
  end

  # @see https://developer.whoop.com/api#tag/Recovery/operation/getRecoveryCollection
  # @return [Hash, nil] The recent recovery collection, or nil when unavailable.
  def get_recoveries
    fetch_collection("recovery", "recoveries", 5.minutes)
  end

  # @see https://developer.whoop.com/api/#tag/Cycle/operation/getCycleCollection
  # @return [Hash, nil] The recent cycle collection, or nil when unavailable.
  def get_cycles
    fetch_collection("cycle", "cycles", 1.minute)
  end

  # Fetches a collection endpoint, caching the response in Redis.
  # @param path [String] The API path under WHOOP_API_URL.
  # @param cache_name [String] The Redis key's suffix.
  # @param ttl [ActiveSupport::Duration] How long to cache it.
  # @return [Hash, nil] The parsed response, or nil when unavailable.
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

  # A valid access token, refreshing when the cached one has expired.
  # @see https://developer.whoop.com/docs/developing/oauth#access-token-expiration
  # @return [String, nil] The token, or nil when it can't be refreshed.
  def get_access_token
    return unless valid_credentials?

    cached_token = $redis.get(access_token_key)
    return cached_token if cached_token.present?

    refresh_access_token
  end

  # Refreshes the access token, serialized by a short Redis lock. Whoop rotates refresh tokens,
  # so concurrent refreshes would race: the loser POSTs an already-rotated token, gets rejected,
  # and can wedge the integration until a manual re-auth. Losers wait for the winner's token.
  # @return [String, nil] The token, or nil when it can't be refreshed.
  def refresh_access_token
    return wait_for_refreshed_token unless $redis.set(refresh_lock_key, "1", nx: true, ex: REFRESH_LOCK_TTL.to_i)

    begin
      # Another request may have finished refreshing between the cache miss and the lock.
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

  # Briefly polls for the token the lock holder is fetching.
  # @return [String, nil] The token, or nil if it doesn't appear in time.
  def wait_for_refreshed_token(attempts: 10, interval: 0.3)
    attempts.times do
      sleep(interval)
      token = $redis.get(access_token_key)
      return token if token.present?
    end

    Rails.logger.warn("Timed out waiting for a concurrent Whoop token refresh.")
    nil
  end

  # Stores the tokens in Redis: the access token expiring a minute before Whoop's own expiry,
  # the refresh token indefinitely.
  # @param token_data [Hash] The OAuth token response.
  def store_tokens(token_data)
    access_token = token_data[:access_token]
    refresh_token = token_data[:refresh_token]
    expires_in = token_data[:expires_in].to_i

    access_cache_duration = [expires_in - 60, 0].max
    $redis.setex(access_token_key, access_cache_duration, access_token)
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
