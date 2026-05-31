require "httparty"
require "uri"

# Interacts with the Whoop API to fetch the most recent sleep, recovery, and strain
# data, and to run the OAuth2 flow that authorizes the app. Access and refresh tokens
# are stored in Redis (shared with the web app) and the access token is refreshed as
# needed, handling refresh-token rotation.
class Whoop < ApplicationService
  WHOOP_API_URL = "https://api.prod.whoop.com/developer/v2"
  WHOOP_OAUTH_URL = "https://api.prod.whoop.com/oauth/oauth2"
  SCOPE = "offline read:recovery read:cycles read:workout read:sleep read:profile read:body_measurement"

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
    nil
  end

  private

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

    access_token_key = "whoop:#{@client_id}:access_token"
    refresh_token_key = "whoop:#{@client_id}:refresh_token"

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
      return
    end

    token_data = JSON.parse(response.body, symbolize_names: true)
    store_tokens(token_data)
    token_data[:access_token]
  rescue StandardError => e
    Rails.logger.error("Error refreshing Whoop token: #{e}")
    nil
  end

  # Stores access and refresh tokens in Redis.
  # @param token_data [Hash] Token response from the OAuth API.
  def store_tokens(token_data)
    access_token = token_data[:access_token]
    refresh_token = token_data[:refresh_token]
    expires_in = token_data[:expires_in].to_i

    access_token_key = "whoop:#{@client_id}:access_token"
    refresh_token_key = "whoop:#{@client_id}:refresh_token"

    # Store the access token with a 1-minute buffer before its actual expiry.
    access_cache_duration = [expires_in - 60, 0].max
    $redis.setex(access_token_key, access_cache_duration, access_token)

    # Store the refresh token without an expiry.
    $redis.set(refresh_token_key, refresh_token) if refresh_token.present?
  end
end
