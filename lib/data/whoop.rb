require 'httparty'
require 'active_support/all'
require 'uri'
require 'securerandom'

# Class to interact with the Whoop API to fetch today's sleep, recovery, and strain data.
class Whoop
  WHOOP_API_URL = 'https://api.prod.whoop.com/developer/v2'
  WHOOP_OAUTH_URL = 'https://api.prod.whoop.com/oauth/oauth2'

  def initialize
    @client_id = ENV['WHOOP_CLIENT_ID']
    @client_secret = ENV['WHOOP_CLIENT_SECRET']
    @redirect_uri = ENV['WHOOP_REDIRECT_URI']
  end

  # Fetches and saves the most recent Whoop data (sleep score, recovery score, strain) to a JSON file.
  def save_data
    cycle_data = get_most_recent_scored_cycle
    cycle_id = cycle_data&.dig(:id)
    sleep_data = get_sleep_for_cycle(cycle_id)
    recovery_data = get_recovery_for_sleep(sleep_data&.dig(:id))
    workout_data = get_workouts(cycle_data&.dig(:start), cycle_data&.dig(:end))
    
    data = {
      physiological_cycle: cycle_data,
      sleep: sleep_data,
      recovery: recovery_data,
      workouts: workout_data
    }
    
    File.write('data/whoop.json', data.to_json)
  end

  # Validates that required environment variables are present
  # @return [Boolean] true if all required variables are set
  def valid_credentials?
    @client_id.present? && @client_secret.present? && @redirect_uri.present?
  end

  # Generates the OAuth authorization URL for initial setup
  # @return [Hash] Hash containing the authorization URL and state parameter
  def get_authorization_url
    return unless valid_credentials?

    state = SecureRandom.hex(4)
    
    params = {
      client_id: @client_id,
      response_type: 'code',
      scope: 'offline read:recovery read:cycles read:workout read:sleep read:profile read:body_measurement',
      redirect_uri: @redirect_uri,
      state: state
    }
    
    url = "#{WHOOP_OAUTH_URL}/auth?" + URI.encode_www_form(params)
    
    { url: url, state: state, redirect_uri: @redirect_uri }
  end

  # Exchanges an authorization code for access and refresh tokens
  # @param authorization_code [String] The authorization code from OAuth callback
  # @return [Hash, nil] Token data hash or nil if exchange failed
  def exchange_code_for_tokens(authorization_code)
    return unless valid_credentials?
    
    params = {
      client_id: @client_id,
      client_secret: @client_secret,
      code: authorization_code,
      grant_type: 'authorization_code',
      redirect_uri: @redirect_uri
    }

    response = HTTParty.post(
      "#{WHOOP_OAUTH_URL}/token",
      body: params,
      headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }
    )

    return unless response.success?

    token_data = JSON.parse(response.body, symbolize_names: true)
    store_tokens(token_data)
    token_data
  rescue StandardError => e
    puts "Error exchanging authorization code: #{e.message}" if ENV['DEBUG']
    nil
  end

  private

  # Fetches the most recent scored cycle from the Whoop API.
  # @return [Hash, nil] The cycle data or nil if unavailable.
  def get_most_recent_scored_cycle
    cycles = get_cycles
    return if cycles.blank?

    cycles&.dig(:records)&.find { |cycle| cycle[:score_state] == 'SCORED' }
  end

  # Fetches the most recent scored non-nap sleep data for a given cycle.
  # @param cycle_id [String] The ID of the cycle to fetch sleep data for.
  # @return [Hash, nil] The sleep data or nil if unavailable.
  def get_sleep_for_cycle(cycle_id)
    sleeps = get_sleeps
    sleeps&.dig(:records)&.find { |sleep| sleep[:cycle_id] == cycle_id && sleep[:score_state] == 'SCORED' && !sleep[:nap] }
  end

  # Fetches the most recent scored recovery data for a given sleep.
  # @param sleep_id [String] The ID of the sleep to fetch recovery data for.
  # @return [Hash, nil] The recovery data or nil if unavailable.
  def get_recovery_for_sleep(sleep_id)
    recoveries = get_recoveries
    recoveries&.dig(:records)&.find { |recovery| recovery[:sleep_id] == sleep_id && recovery[:score_state] == 'SCORED' }
  end

  # Fetches most recent sleep data from the Whoop API.
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
      "#{WHOOP_API_URL}/activity/sleep",
      headers: { "Authorization" => "Bearer #{access_token}" }
    )

    return unless response.success?
    
    $redis.setex(cache_key, 5.minutes, response.body)
    
    JSON.parse(response.body, symbolize_names: true)
  end

  # Fetches most recent recovery data from the Whoop API.
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
      "#{WHOOP_API_URL}/recovery",
      headers: { "Authorization" => "Bearer #{access_token}" }
    )

    return unless response.success?

    $redis.setex(cache_key, 5.minutes, response.body)
    
    JSON.parse(response.body, symbolize_names: true)
  end

  # Fetches most recent cycle data from the Whoop API.
  # @see https://developer.whoop.com/api/#tag/Cycle/operation/getCycleCollection
  # @see https://developer.whoop.com/docs/developing/user-data/cycle/
  # @return [Hash, nil] The full cycle data or nil if unavailable.
  def get_cycles
    access_token = get_access_token
    return if access_token.blank?

    cache_key = "whoop:#{@client_id}:cycles"
    cached_response = $redis.get(cache_key)

    return JSON.parse(cached_response, symbolize_names: true) if cached_response.present?

    response = HTTParty.get(
      "#{WHOOP_API_URL}/cycle",
      headers: { "Authorization" => "Bearer #{access_token}" }
    )

    return unless response.success?

    $redis.setex(cache_key, 1.minute, response.body)
    JSON.parse(response.body, symbolize_names: true)
  end

  # Fetches most recent workouts from the Whoop API.
  # @param start_date [String] The start date of the workouts to fetch.
  # @param end_date [String] The end date of the workouts to fetch.
  # @see https://developer.whoop.com/api/#tag/Workout/operation/getWorkoutCollection
  # @see https://developer.whoop.com/docs/developing/user-data/workout
  # @return [Hash, nil] The workout data or nil if unavailable.
  def get_workouts(start_date = nil, end_date = nil)
    access_token = get_access_token
    return if access_token.blank?

    cache_key = "whoop:#{@client_id}:workouts:#{start_date.to_i}:#{end_date.to_i}"
    cached_response = $redis.get(cache_key)

    return JSON.parse(cached_response, symbolize_names: true) if cached_response.present?

    response = HTTParty.get(
      "#{WHOOP_API_URL}/activity/workout",
      headers: { "Authorization" => "Bearer #{access_token}" },
      query: { start: start_date, end: end_date, limit: 25 }
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
    return unless valid_credentials?

    access_token_key = "whoop:#{@client_id}:access_token"
    refresh_token_key = "whoop:#{@client_id}:refresh_token"
    # Check if we have a cached access token
    cached_token = $redis.get(access_token_key)
    return cached_token if cached_token.present?

    # Get refresh token from Redis
    refresh_token = $redis.get(refresh_token_key)
    if refresh_token.blank?
      puts "❎ No Whoop refresh token found. Run 'bundle exec rake oauth:whoop' to get a new refresh token."
      return
    end

    # Refresh the access token
    refresh_params = {
      'grant_type' => 'refresh_token',
      'refresh_token' => refresh_token,
      'client_id' => @client_id,
      'client_secret' => @client_secret,
      'scope' => 'offline read:recovery read:cycles read:workout read:sleep read:profile read:body_measurement'
    }

    response = HTTParty.post(
      "#{WHOOP_OAUTH_URL}/token",
      body: refresh_params,
      headers: { 'Content-Type' => 'application/x-www-form-urlencoded' }
    )

    unless response.success?
      puts "❎ Failed to get Whoop access token (HTTP #{response.code}: #{response.body}). Run 'bundle exec rake oauth:whoop' to get a new refresh token."
      return
    end

    token_data = JSON.parse(response.body, symbolize_names: true)
    access_token = token_data[:access_token]
    store_tokens(token_data)

    access_token
  rescue StandardError => e
    puts "Error refreshing Whoop token: #{e.message}" if ENV['DEBUG']
    nil
  end

  # Stores access and refresh tokens in Redis
  # @param token_data [Hash] Token response from OAuth API
  def store_tokens(token_data)
    access_token = token_data[:access_token]
    refresh_token = token_data[:refresh_token]
    expires_in = token_data[:expires_in].to_i
    
    access_token_key = "whoop:#{@client_id}:access_token"
    refresh_token_key = "whoop:#{@client_id}:refresh_token"
    
    # Store access token with expiration (1-minute buffer)
    access_cache_duration = [expires_in - 60, 0].max
    $redis.setex(access_token_key, access_cache_duration, access_token)
    
    # Store refresh token (no expiration)
    $redis.set(refresh_token_key, refresh_token) if refresh_token.present?
  end
end
