require "httparty"
require "uri"

# Gets the sleep, recovery, and strain data from the Whoop API, and does the OAuth2 flow that
# authorizes the app. The tokens are in Redis. There is no database, thus the refresh token is
# the only permanent credential. The app refreshes the access token when it is necessary, and it
# obeys the rotation.
class Whoop < ApplicationService
  include ParallelUpstreams

  WHOOP_API_URL = "https://api.prod.whoop.com/developer/v2"
  WHOOP_OAUTH_URL = "https://api.prod.whoop.com/oauth/oauth2"
  SCOPE = "offline read:recovery read:cycles read:workout read:sleep read:profile read:body_measurement"
  # The maximum time that one token refresh can hold the lock before the app counts it as dead.
  REFRESH_LOCK_TTL = 30.seconds

  def initialize
    @client_id = ENV["WHOOP_CLIENT_ID"]
    @client_secret = ENV["WHOOP_CLIENT_SECRET"]
    @redirect_uri = ENV["WHOOP_REDIRECT_URI"]
  end

  # @return [Hash, nil] The most recent scored :physiological_cycle, :sleep, and :recovery, or
  #   nil if one of them is absent. The widget then renders nothing.
  def stats
    # Only the *filter* below makes a chain: a sleep goes with a cycle, and a recovery goes with
    # a sleep. The three collection fetches do not depend on each other, thus they run at the
    # same time, and not as three requests in sequence on a cold cache.
    collections = in_parallel(
      cycles: -> { rescue_with(context: "Whoop cycles") { get_cycles } },
      sleeps: -> { rescue_with(context: "Whoop sleeps") { get_sleeps } },
      recoveries: -> { rescue_with(context: "Whoop recoveries") { get_recoveries } }
    )

    cycle = most_recent_scored_cycle(collections[:cycles])
    sleep = sleep_for_cycle(collections[:sleeps], cycle&.dig(:id))
    recovery = recovery_for_sleep(collections[:recoveries], sleep&.dig(:id))

    return if cycle.blank? || sleep.blank? || recovery.blank?

    # ⚠️ A record can be SCORED and still have no value for the one sub-score that the widget
    # renders. The presenter rounds all three values, and at that point the render_empty of the
    # controller is behind us. Thus the check must be here, where "no data" is still possible.
    return if cycle.dig(:score, :strain).nil? ||
              sleep.dig(:score, :sleep_performance_percentage).nil? ||
              recovery.dig(:score, :recovery_score).nil?

    {
      physiological_cycle: cycle,
      sleep: sleep,
      recovery: recovery
    }
  end

  # @return [Boolean] True if the OAuth credentials are available.
  def valid_credentials?
    @client_id.present? && @client_secret.present? && @redirect_uri.present?
  end

  # The numeric id of the authenticated user. The app uses it to check that a webhook payload
  # belongs to the configured athlete. The cache keeps it for a day, because the webhook
  # controller calls this in the request path and Whoop needs a 2xx in approximately one second.
  # @return [Integer]
  # @raise [ApplicationService::HttpError] If the profile fetch fails.
  def user_id
    cached_json(user_id_key, expires_in: 1.day) do
      authed_get!("user/profile/basic")[:user_id]
    end
  end

  # Gets one workout by UUID.
  # @return [Hash, nil] The workout in the standard shape, or nil if it is absent or has no
  #   score. A workout with no score has no strain.
  def get_workout(uuid)
    workout = authed_get_or_nil("activity/workout/#{uuid}")
    return if workout.nil? || workout[:score_state] != "SCORED" || workout[:score].nil?

    normalize_workout(workout)
  end

  # Gets one sleep by UUID. The name is get_sleep, thus it cannot hide Kernel#sleep, which
  # wait_for_refreshed_token uses.
  # @return [Hash, nil] The raw sleep, or nil if it is absent or has no score.
  def get_sleep(uuid)
    sleep_data = authed_get_or_nil("activity/sleep/#{uuid}")
    return if sleep_data.nil? || sleep_data[:score_state] != "SCORED"

    sleep_data
  end

  # Gets the recovery with a score for a cycle. Whoop v2 has no GET by recovery id, because the
  # cycle is the key.
  # @return [Hash, nil] The raw recovery, or nil if it is absent or has no score.
  def get_recovery_for_cycle(cycle_id)
    recovery = authed_get_or_nil("cycle/#{cycle_id}/recovery")
    return if recovery.nil? || recovery[:score_state] != "SCORED"

    recovery
  end

  # Gets each cycle with a window that can touch the given range, one page at a time. A caller
  # gives a range with extra time at each end, because a cycle goes in a group by its end time in
  # the timezone of the athlete.
  # @param start_ymd [String] The start date, as YYYY-MM-DD.
  # @param end_ymd [String] The end date, as YYYY-MM-DD.
  # @return [Array<Hash>] The raw cycles.
  # @raise [ApplicationService::HttpError] If one page fails, thus the job runs again.
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

  # @param state [String] A value with no meaning. The app checks it when Whoop redirects back.
  # @return [String, nil] The OAuth authorization URL, or nil if there are no credentials.
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

  # Changes an authorization code into tokens and stores them in Redis.
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
    store_account_email!
    token_data
  rescue StandardError => e
    Rails.logger.error("Error exchanging Whoop authorization code: #{e}")
    report_upstream_error(e, context: "Whoop OAuth code exchange")
    nil
  end

  # The email address of the authorized athlete. The Connected apps page names the account with
  # it.
  #
  # ⚠️ This reads Redis and makes no request, on purpose. That page shows the state of each
  # integration on each load, thus a fetch here would put an upstream failure in the path of the
  # admin navigation. `store_account_email!` is what writes the value.
  # @return [String, nil] The address, or nil before the app stored one.
  def account_email
    $redis.get(account_email_key).presence
  end

  # Gets the profile of the athlete and stores the email address. `exchange_code_for_tokens` calls
  # this, and `WhoopTokenRefreshJob` calls it for a connection that this app made before this code
  # existed.
  #
  # ⚠️ It fails soft. The address is a label for the admin, thus a Whoop that is not available must
  # never stop an authorization or a token refresh.
  # @return [String, nil] The address, or nil if the fetch failed.
  def store_account_email!
    email = rescue_with(context: "Whoop profile") { authed_get_or_nil("user/profile/basic") }&.dig(:email)
    return if email.blank?

    $redis.set(account_email_key, email)
    email
  end

  # @return [Boolean] True if an account is connected now. The refresh token is the only
  #   permanent credential, because there is no database. Thus the token *is* the connection.
  def connected?
    return false unless valid_credentials?

    $redis.exists?(refresh_token_key)
  end

  # The details of the last refused token refresh, when the integration cannot work.
  #
  # ⚠️ A refused refresh does NOT remove the stored tokens, thus `connected?` continues to report
  # true while nothing works. This is the only thing that shows the difference.
  # @return [Hash, nil] `{ code:, at: }`, or nil if the last refresh was successful.
  def refresh_error
    raw = $redis.get(refresh_error_key)
    return if raw.blank?

    JSON.parse(raw, symbolize_names: true)
  end

  # Does a token refresh even when the cached access token is still good. Thus the app continues
  # to use the refresh token, which rotates. In all other conditions Whoop refreshes only when it
  # is necessary, and a refresh token with no use expires. WhoopTokenRefreshJob calls this.
  # @return [String, nil] The new access token, or nil if the refresh failed.
  def refresh_tokens!
    refresh_access_token(force: true)
  end

  # Removes the stored credentials and disconnects the account.
  #
  # ⚠️ The cached user_id also goes away. Webhooks::WhoopController checks the user_id of each
  # payload against it. Thus a copy that stays would continue to authorize webhooks for an
  # account with no tokens. The app would accept such a webhook, then fail later, because it has
  # no access token for the fetch.
  # @return [void]
  def disconnect!
    $redis.del(access_token_key, refresh_token_key, user_id_key, refresh_lock_key, refresh_error_key,
               account_email_key)
    nil
  end

  private

  # Changes the Whoop sport_name values into the names in the type map of ActivityMatcher.
  # sport_name is the stable field. Whoop made sport_id obsolete after 2025-09-01.
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

  # Changes a workout with a score into the fields that the webhook flow uses. start_time stays
  # an instant, and each call site renders it in the timezone of the athlete.
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

  # GETs an API path with authentication. It raises on failure, thus Sidekiq can do the job
  # again. The cached collection methods are different: they give a smaller result.
  # @raise [RuntimeError] If there is no access token.
  # @raise [ApplicationService::HttpError] If the response is not a success.
  def authed_get!(path, query = {})
    access_token = get_access_token
    raise "No Whoop access token available — visit /whoop/auth to authorize" if access_token.blank?

    get_json!(
      "#{WHOOP_API_URL}/#{path}",
      query: query,
      headers: { "Authorization" => "Bearer #{access_token}" }
    )
  end

  # The same as authed_get!, but a 404 is not an error. Each other error goes to the caller,
  # thus Sidekiq can do the job again.
  def authed_get_or_nil(path)
    authed_get!(path)
  rescue ApplicationService::HttpError => e
    raise unless e.status == 404
    nil
  end

  # @return [Hash, nil] The most recent cycle with a score, or nil if it is not available.
  # @param cycles [Hash, nil] The cycle collection.
  # @return [Hash, nil] The most recent cycle with a score, or nil if it is not available.
  def most_recent_scored_cycle(cycles)
    cycles&.dig(:records)&.find { |cycle| cycle[:score_state] == "SCORED" }
  end

  # @param sleeps [Hash, nil] The sleep collection.
  # @param cycle_id [String, nil] The id of the cycle.
  # @return [Hash, nil] Its most recent sleep with a score that is not a nap, or nil if it is not
  #   available.
  def sleep_for_cycle(sleeps, cycle_id)
    return if cycle_id.blank?

    sleeps&.dig(:records)&.find { |sleep| sleep[:cycle_id] == cycle_id && sleep[:score_state] == "SCORED" && !sleep[:nap] }
  end

  # @param recoveries [Hash, nil] The recovery collection.
  # @param sleep_id [String, nil] The id of the sleep.
  # @return [Hash, nil] Its most recent recovery with a score, or nil if it is not available.
  def recovery_for_sleep(recoveries, sleep_id)
    return if sleep_id.blank?

    recoveries&.dig(:records)&.find { |recovery| recovery[:sleep_id] == sleep_id && recovery[:score_state] == "SCORED" }
  end

  # @see https://developer.whoop.com/api#tag/Sleep/operation/getSleepCollection
  # @return [Hash, nil] The recent sleep collection, or nil if it is not available.
  def get_sleeps
    fetch_collection("activity/sleep", "sleeps", 5.minutes)
  end

  # @see https://developer.whoop.com/api#tag/Recovery/operation/getRecoveryCollection
  # @return [Hash, nil] The recent recovery collection, or nil if it is not available.
  def get_recoveries
    fetch_collection("recovery", "recoveries", 5.minutes)
  end

  # @see https://developer.whoop.com/api/#tag/Cycle/operation/getCycleCollection
  # @return [Hash, nil] The recent cycle collection, or nil if it is not available.
  def get_cycles
    fetch_collection("cycle", "cycles", 1.minute)
  end

  # Gets a collection endpoint and caches the response in Redis.
  # @param path [String] The API path below WHOOP_API_URL.
  # @param cache_name [String] The end of the Redis key.
  # @param ttl [ActiveSupport::Duration] The time to keep it in the cache.
  # @return [Hash, nil] The parsed response, or nil if it is not available.
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

  # A good access token. It refreshes the token if the cached one expired.
  # @see https://developer.whoop.com/docs/developing/oauth#access-token-expiration
  # @return [String, nil] The token, or nil if the app cannot refresh it.
  def get_access_token
    return unless valid_credentials?

    cached_token = read_secret(access_token_key)
    return cached_token if cached_token.present?

    refresh_access_token
  end

  # Refreshes the access token. A short Redis lock lets only one refresh run at a time. Whoop
  # rotates its refresh tokens. Thus two refreshes at the same time would be a race: the second
  # one POSTs a token that already rotated, Whoop refuses it, and the integration can stop until
  # someone does a manual re-authorization. The second refresh waits for the token of the first.
  #
  # ⚠️ force: does not do the cache check in the lock, but it always takes the lock. A forced
  # refresh at the same time as a refresh in a request is the rotation race that the lock stops.
  # @param force [Boolean] True to refresh even when a cached access token is still good.
  # @return [String, nil] The token, or nil if the app cannot refresh it.
  def refresh_access_token(force: false)
    return wait_for_refreshed_token unless $redis.set(refresh_lock_key, "1", nx: true, ex: REFRESH_LOCK_TTL.to_i)

    begin
      unless force
        # Another request can complete a refresh between the cache miss and the lock.
        cached_token = read_secret(access_token_key)
        return cached_token if cached_token.present?
      end

      refresh_token = read_secret(refresh_token_key)
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
        record_refresh_error(response.code)
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

  # Looks for the token that the holder of the lock gets, for a short time.
  # @return [String, nil] The token, or nil if it does not come in time.
  def wait_for_refreshed_token(attempts: 10, interval: 0.3)
    attempts.times do
      sleep(interval)
      token = read_secret(access_token_key)
      return token if token.present?
    end

    Rails.logger.warn("Timed out waiting for a concurrent Whoop token refresh.")
    nil
  end

  # Stores the tokens in Redis. The access token expires one minute before the Whoop expiry
  # time. The refresh token has no expiry time.
  # @param token_data [Hash] The OAuth token response.
  def store_tokens(token_data)
    access_token = token_data[:access_token]
    refresh_token = token_data[:refresh_token]
    expires_in = token_data[:expires_in].to_i

    # ⚠️ This is a check, and it does not set the TTL to 0. Redis refuses a TTL of 0, and the
    # rescue of the caller hides the raise. Thus an expires_in that is absent or less than 60s
    # stopped the integration with no message. The code stores the refresh token in all
    # conditions, which lets the next attempt recover.
    # ⚠️ Both tokens are encrypted at rest, as each other credential is. Refer to WhoopCredentials.
    access_cache_duration = expires_in - 60
    $redis.setex(access_token_key, access_cache_duration, WhoopCredentials.seal(access_token)) if access_cache_duration.positive?
    $redis.set(refresh_token_key, WhoopCredentials.seal(refresh_token)) if refresh_token.present?

    # This also covers the re-authorization path, because exchange_code_for_tokens comes here.
    $redis.del(refresh_error_key)
  end

  # Records a refused refresh. Thus the Connected apps page of the admin can say that the
  # integration needs a new authorization, and it does not show the integration as good for all
  # time.
  #
  # ⚠️ Record a 4xx only. A 5xx or a timeout means that Whoop is not available, and not that the
  # refresh token is dead. A mark for those would tell the owner to authorize again while the
  # stored token is good, and the next scheduled refresh recovers by itself. This has no TTL:
  # only a successful refresh (store_tokens) or disconnect! removes it, because the problem is
  # real until one of those happens.
  # @param code [Integer, String] The HTTP status from the Whoop token endpoint.
  def record_refresh_error(code)
    return unless code.to_i.between?(400, 499)

    $redis.set(refresh_error_key, { code: code.to_i, at: Time.current.utc.iso8601 }.to_json)
  end

  # Reads an encrypted token. A value from before the encryption reads as it is, and the next
  # refresh stores it encrypted. Whoop rotates the refresh token at each refresh, thus such a value
  # goes away by itself.
  # @param key [String] The Redis key.
  # @return [String, nil]
  def read_secret(key)
    raw = $redis.get(key)
    return if raw.blank?

    WhoopCredentials.open(raw) || raw
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

  def refresh_error_key
    "whoop:#{@client_id}:refresh_error"
  end

  def user_id_key
    "whoop:#{@client_id}:user_id"
  end

  def account_email_key
    "whoop:#{@client_id}:account_email"
  end
end
