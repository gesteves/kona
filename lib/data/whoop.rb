require 'httparty'
require 'active_support/all'

# Class to interact with the Whoop API to fetch today's sleep, recovery, and strain data.
class Whoop
  WHOOP_API_URL = 'https://api.prod.whoop.com/developer'
  OAUTH_TOKEN_URL = 'https://api.prod.whoop.com/oauth/oauth2/token'

  def initialize(timezone = "America/Denver")
    @client_id = ENV['WHOOP_CLIENT_ID']
    @client_secret = ENV['WHOOP_CLIENT_SECRET']
    @redirect_uri = ENV['WHOOP_REDIRECT_URI']
    @timezone = timezone
  end

  # Fetches and saves the most recent Whoop data (sleep score, recovery score, strain) to a JSON file.
  def save_data
    # Get the most recent scored cycle.
    cycle_data = get_most_recent_scored_cycle
    cycle_id = cycle_data&.dig(:id)
    sleep_data = get_sleep_for_cycle(cycle_id)
    recovery_data = get_recovery_for_sleep(sleep_data&.dig(:id))
    
    data = {
      physiological_cycle: cycle_data,
      sleep: sleep_data,
      recovery: recovery_data
    }
    
    File.write('data/whoop.json', data.to_json)
  end

  private

  # Fetches sleep data from the Whoop API.
  # @see https://developer.whoop.com/api#tag/Sleep/operation/getSleepCollection
  # @see https://developer.whoop.com/docs/developing/user-data/sleep/
  # @return [Hash, nil] The full sleep data or nil if unavailable.
  def get_sleeps
    access_token = get_access_token
    return if access_token.blank?

    cache_key = "whoop:#{@client_id}:sleeps"
    cached_response = $redis.get(cache_key)

    return JSON.parse(cached_response, symbolize_names: true) if cached_response.present?

    response = HTTParty.get(
      "#{WHOOP_API_URL}/v2/activity/sleep",
      headers: { "Authorization" => "Bearer #{access_token}" }
    )

    return unless response.success?
    
    $redis.setex(cache_key, 5.minutes, response.body)
    
    JSON.parse(response.body, symbolize_names: true)
  end

  # Fetches recovery data.
  # @see https://developer.whoop.com/api#tag/Recovery/operation/getRecoveryCollection
  # @see https://developer.whoop.com/docs/developing/user-data/recovery/
  # @return [Hash, nil] The recovery data or nil if unavailable.
  def get_recoveries
    access_token = get_access_token
    return if access_token.blank?

    cache_key = "whoop:#{@client_id}:recoveries"
    cached_response = $redis.get(cache_key)

    return JSON.parse(cached_response, symbolize_names: true) if cached_response.present?

    response = HTTParty.get(
      "#{WHOOP_API_URL}/v2/recovery",
      headers: { "Authorization" => "Bearer #{access_token}" }
    )

    return unless response.success?

    $redis.setex(cache_key, 5.minutes, response.body)
    
    JSON.parse(response.body, symbolize_names: true)
  end

  # Fetches cycle data from the Whoop API.
  # @see https://developer.whoop.com/api/#tag/Cycle/operation/getCycleCollection
  # @see https://developer.whoop.com/docs/developing/user-data/cycle/
  # @return [Hash, nil] The full cycle data or nil if unavailable.
  def get_cycles
    access_token = get_access_token
    return if access_token.blank?

    cache_key = "whoop:#{@client_id}:cycles"
    cached_response = $redis.get(cache_key)

    return JSON.parse(cached_response, symbolize_names: true) if cached_response.present?

    # Get today's cycle data
    response = HTTParty.get(
      "#{WHOOP_API_URL}/v2/cycle",
      headers: { "Authorization" => "Bearer #{access_token}" }
    )

    return unless response.success?

    $redis.setex(cache_key, 1.minute, response.body)
    JSON.parse(response.body, symbolize_names: true)
  end

  # Gets a valid access token, refreshing if necessary.
  # Handles token rotation by storing new refresh tokens when they're returned.
  # @see https://developer.whoop.com/docs/developing/oauth#access-token-expiration
  # @return [String, nil] Access token or nil if unable to refresh.
  def get_access_token
    return if @client_id.blank? || @client_secret.blank?

    access_token_key = "whoop:#{@client_id}:access_token"
    refresh_token_key = "whoop:#{@client_id}:refresh_token"
    # Check if we have a cached access token
    cached_token = $redis.get(access_token_key)
    return cached_token if cached_token.present?

    # Get refresh token from Redis
    refresh_token = $redis.get(refresh_token_key)
    return if refresh_token.blank?

    # Refresh the access token
    refresh_params = {
      'grant_type' => 'refresh_token',
      'refresh_token' => refresh_token,
      'client_id' => @client_id,
      'client_secret' => @client_secret,
      'scope' => 'offline read:recovery read:cycles read:workout read:sleep read:profile read:body_measurement'
    }

    response = HTTParty.post(
      OAUTH_TOKEN_URL,
      body: refresh_params,
      headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }
    )

    unless response.success?
      puts "Failed to get Whoop access token (HTTP #{response.code}: #{response.body}). Run 'bundle exec rake oauth:whoop' to get a new refresh token."
      return
    end

    token_data = JSON.parse(response.body, symbolize_names: true)
    access_token = token_data[:access_token]
    new_refresh_token = token_data[:refresh_token]
    expires_in = token_data[:expires_in] || 3600

    # Store the new access token with expiration (5 minute buffer)
    cache_duration = [expires_in - 300, 300].max
    $redis.setex(access_token_key, cache_duration, access_token)

    # Store the new refresh token (single-use tokens)
    if new_refresh_token.present?
      $redis.set(refresh_token_key, new_refresh_token)
    end

    access_token
  rescue StandardError => e
    puts "Error refreshing Whoop token: #{e.message}" if ENV['DEBUG']
    nil
  end

  # Fetches the most recent scored cycle from the Whoop API.
  # @return [Hash, nil] The cycle data or nil if unavailable.
  def get_most_recent_scored_cycle
    cycles = get_cycles
    return if cycles.blank?

    cycles&.dig(:records)&.find { |cycle| cycle[:score_state] == 'SCORED' }
  end

  # Fetches the sleep data for a given cycle.
  # @param cycle_id [String] The ID of the cycle to fetch sleep data for.
  # @return [Hash, nil] The sleep data or nil if unavailable.
  def get_sleep_for_cycle(cycle_id)
    sleeps = get_sleeps
    sleeps&.dig(:records)&.find { |sleep| sleep[:cycle_id] == cycle_id }
  end

  # Fetches the recovery data for a given sleep.
  # @param sleep_id [String] The ID of the sleep to fetch recovery data for.
  # @return [Hash, nil] The recovery data or nil if unavailable.
  def get_recovery_for_sleep(sleep_id)
    recoveries = get_recoveries
    recoveries&.dig(:records)&.find { |recovery| recovery[:sleep_id] == sleep_id }
  end
end
