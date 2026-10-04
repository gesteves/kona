require "httparty"
require "uri"

# Connects a Strava athlete with the OAuth2 authorization code flow, and writes the name and the
# description of an activity.
#
# ⚠️ This integration WRITES to Strava. It reads only the name and the description of an
# activity, to keep the words that the owner wrote there. No other Strava data goes to an LLM or to
# a page that another person can see.
# @see https://developers.strava.com/docs/authentication/
class Strava < ApplicationService
  AUTHORIZE_URL = "https://www.strava.com/oauth/authorize".freeze
  TOKEN_URL = "https://www.strava.com/oauth/token".freeze
  DEAUTHORIZE_URL = "https://www.strava.com/oauth/deauthorize".freeze
  API_URL = "https://www.strava.com/api/v3".freeze

  # The id of the webhook subscription, which `rake strava:subscribe` writes. The webhook accepts
  # only the events of this subscription.
  # ⚠️ This is a durable record with no other copy, thus `rake redis:export` names it. After a flush,
  # run `rake strava:subscribe` again: it finds the subscription that exists and stores its id.
  SUBSCRIPTION_KEY = "strava:subscription_id".freeze

  # ⚠️ Strava permits an edit only of an activity that the read scope can see. Thus an activity that
  # only the athlete can see needs `activity:read_all`, and `activity:write` alone is not enough.
  # The athlete can clear a scope on the Strava authorization screen, thus the callback checks the
  # scopes that came back.
  SCOPES = %w[activity:read_all activity:write].freeze

  # The seconds that each call to Strava can take. ⚠️ `connect!` runs in the OAuth callback, which is
  # a request with a 20-second rack-timeout.
  REQUEST_TIMEOUT = 10

  # An access token that expires within this time counts as expired. A token lasts 6 hours.
  REFRESH_MARGIN = 5.minutes

  # One refresh at a time. Strava can rotate the refresh token, thus a second refresh at the same
  # moment could POST a token that is no longer good.
  REFRESH_LOCK_KEY = "strava:refresh_lock".freeze
  REFRESH_LOCK_TTL = 30
  # The time that a second caller waits for the token of the refresh in progress.
  REFRESH_WAIT_ATTEMPTS = 30
  REFRESH_WAIT_INTERVAL = 0.5

  def initialize(credentials = StravaCredentials.fetch)
    @client_id = ENV["STRAVA_CLIENT_ID"]
    @client_secret = ENV["STRAVA_CLIENT_SECRET"]
    @credentials = credentials
  end

  # @param scope [String, nil] The comma-separated `scope` parameter of the callback.
  # @return [Boolean] True if the athlete granted each scope in SCOPES.
  def self.granted_scopes?(scope)
    (SCOPES - scope.to_s.split(",").map(&:strip)).empty?
  end

  # @return [String, nil] The id of the webhook subscription of this app.
  def self.subscription_id = $redis.get(SUBSCRIPTION_KEY).presence

  # @return [Boolean] True if the Strava app credentials are available.
  def valid_credentials? = @client_id.present? && @client_secret.present?

  # @return [Boolean] True if an athlete is connected now.
  def connected? = valid_credentials? && @credentials.usable?

  # @return [String, nil] The Strava id of the connected athlete.
  def athlete_id = @credentials.athlete_id

  # @return [String, nil] The name of the connected athlete.
  def athlete_name = @credentials.athlete_name

  # @return [Hash, nil] `{ code:, at: }` of the last refused refresh, or nil when the token is good.
  def refresh_error = @credentials.refresh_error

  # ⚠️ The redirect URI is not an environment variable, and the caller gives it from the request.
  # Strava checks only its host, against the Authorization Callback Domain of the app.
  # @param state [String] A value with no meaning. The callback compares it.
  # @param redirect_uri [String] The callback URL of this app.
  # @return [String, nil] The authorization URL, or nil with no app credentials.
  def authorization_url(state, redirect_uri:)
    return unless valid_credentials?

    query = {
      client_id: @client_id,
      redirect_uri: redirect_uri,
      response_type: "code",
      approval_prompt: "auto",
      scope: SCOPES.join(","),
      state: state
    }

    "#{AUTHORIZE_URL}?#{URI.encode_www_form(query)}"
  end

  # Changes the authorization code into tokens, and stores them with the athlete.
  # @param code [String] The code from the callback.
  # @return [Boolean] True if the athlete is connected now.
  def connect!(code)
    return false unless valid_credentials?

    rescue_with(false, context: "Strava token exchange") do
      token = post_json(
        TOKEN_URL,
        body: { client_id: @client_id, client_secret: @client_secret, code: code, grant_type: "authorization_code" },
        timeout: REQUEST_TIMEOUT
      )
      athlete = token&.dig(:athlete)
      next false if token.blank? || token[:refresh_token].blank? || athlete.blank?

      StravaCredentials.store_athlete(
        athlete_id: athlete[:id],
        athlete_name: [ athlete[:firstname], athlete[:lastname] ].compact_blank.join(" ").presence || athlete[:username],
        access_token: token[:access_token],
        refresh_token: token[:refresh_token],
        expires_at: token[:expires_at]
      )
      true
    end
  end

  # Tells Strava to revoke the access, then removes the stored tokens.
  #
  # ⚠️ It clears the store whether the revoke works or not: Strava can be away, and a disconnect that
  # the owner asked for must not depend on that.
  # @return [void]
  def disconnect!
    token = @credentials.access_token
    if token.present?
      rescue_with(context: "Strava deauthorize") do
        HTTParty.post(DEAUTHORIZE_URL, body: { access_token: token }, timeout: REQUEST_TIMEOUT)
      end
    end
    nil
  ensure
    StravaCredentials.clear
  end

  # The name and the description of one activity. The code reads no other field.
  # @param id [String, Integer] The Strava activity id.
  # @return [Hash] `{ name:, description: }`.
  # @raise [StandardError] On a failure, thus the job does the work again.
  def activity(id)
    body = get_json!("#{API_URL}/activities/#{id}", headers: auth_headers, timeout: REQUEST_TIMEOUT)
    { name: body[:name], description: body[:description] }
  end

  # Updates the given fields of one activity. Each other field stays the same.
  # @param id [String, Integer] The Strava activity id.
  # @param fields [Hash] For example `name:` and `description:`.
  # @return [void]
  # @raise [StandardError] On a failure, thus the job does the work again.
  def update_activity!(id, **fields)
    put_json!(
      "#{API_URL}/activities/#{id}",
      body: fields.to_json,
      headers: auth_headers.merge("Content-Type" => "application/json"),
      timeout: REQUEST_TIMEOUT
    )
    nil
  end

  # Makes the webhook subscription of this app, or finds the one that exists, and stores its id.
  #
  # ⚠️ Strava permits ONE subscription for each app. It also GETs the callback with a challenge
  # before it answers, thus the app must already serve `/webhooks/strava` with the same
  # STRAVA_WEBHOOK_VERIFY_TOKEN.
  # @param callback_url [String] The public URL of `/webhooks/strava`.
  # @return [String] The id of the subscription.
  # @raise [RuntimeError] When a subscription for a different URL exists, or when Strava refuses.
  def subscribe!(callback_url)
    app = { client_id: @client_id, client_secret: @client_secret }
    existing = Array(get_json!("#{API_URL}/push_subscriptions", query: app, timeout: REQUEST_TIMEOUT)).first

    id =
      if existing.nil?
        verify_token = ENV["STRAVA_WEBHOOK_VERIFY_TOKEN"].presence
        raise "Set STRAVA_WEBHOOK_VERIFY_TOKEN first." if verify_token.nil?

        created = post_json!(
          "#{API_URL}/push_subscriptions",
          body: app.merge(callback_url: callback_url, verify_token: verify_token),
          timeout: REQUEST_TIMEOUT
        )
        created[:id]
      elsif existing[:callback_url] == callback_url
        existing[:id]
      else
        raise "Subscription #{existing[:id]} already uses #{existing[:callback_url]}. Delete it in Strava first."
      end

    $redis.set(SUBSCRIPTION_KEY, id.to_s)
    id.to_s
  end

  private

  # @raise [RuntimeError] With no access token, thus the job does the work again.
  def auth_headers
    token = access_token
    raise "No Strava access token. Connect Strava on the Connected apps page." if token.blank?

    { "Authorization" => "Bearer #{token}" }
  end

  # A good access token. It refreshes the token when it is about to expire.
  # @return [String, nil]
  def access_token
    return unless connected?
    return @credentials.access_token unless @credentials.stale?(REFRESH_MARGIN)

    refresh_access_token
  end

  # Refreshes the access token under the lock. A second caller waits for the token of the first.
  # @return [String, nil] The new token, or nil when Strava refused it or the call failed.
  def refresh_access_token
    return wait_for_refreshed_token unless $redis.set(REFRESH_LOCK_KEY, "1", nx: true, ex: REFRESH_LOCK_TTL)

    begin
      # Another caller can complete a refresh between the read and the lock.
      current = StravaCredentials.fetch
      return current.access_token unless current.stale?(REFRESH_MARGIN)

      response = HTTParty.post(
        TOKEN_URL,
        body: {
          client_id: @client_id, client_secret: @client_secret,
          grant_type: "refresh_token", refresh_token: current.refresh_token
        },
        timeout: REQUEST_TIMEOUT
      )

      unless response.success?
        Rails.logger.warn("Failed to refresh the Strava token (HTTP #{response.code}).")
        report_upstream_error("HTTP #{response.code}", context: "Strava token refresh", status: response.code)
        StravaCredentials.record_refresh_error(response.code)
        return
      end

      token = JSON.parse(response.body, symbolize_names: true)
      StravaCredentials.store_tokens(
        access_token: token[:access_token], refresh_token: token[:refresh_token], expires_at: token[:expires_at]
      )
      @credentials = StravaCredentials.fetch
      token[:access_token]
    ensure
      $redis.del(REFRESH_LOCK_KEY)
    end
  rescue StandardError => e
    Rails.logger.error("Error refreshing the Strava token: #{e}")
    report_upstream_error(e, context: "Strava token refresh")
    nil
  end

  # @return [String, nil] The token of the refresh in progress, or nil when it does not come in time.
  def wait_for_refreshed_token
    REFRESH_WAIT_ATTEMPTS.times do
      sleep(REFRESH_WAIT_INTERVAL)
      current = StravaCredentials.fetch
      return current.access_token unless current.stale?(REFRESH_MARGIN)
    end

    Rails.logger.warn("Timed out waiting for a concurrent Strava token refresh.")
    nil
  end
end
