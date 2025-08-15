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

  # Fetches and saves today's Whoop data (sleep score, recovery score, strain) to a JSON file.
  def save_data
    # Get sleep data first, then find the corresponding recovery
    sleep_data = get_sleep_data
    recovery_data = get_recovery_for_sleep(sleep_data['id']) if sleep_data
    
    data = {
      sleep_score: sleep_data&.dig('score', 'sleep_performance_percentage'),
      recovery_score: recovery_data&.dig('score', 'recovery_score'),
      strain: strain
    }

    File.open('data/whoop.json', 'w') do |f|
      f << data.to_json
    end
  end

  private

  # Fetches the most recent SCORED sleep data from the Whoop API.
  # @return [Hash, nil] The full sleep record or nil if unavailable.
  def get_sleep_data
    access_token = get_access_token
    return if access_token.blank?

    today_start = Time.current.in_time_zone(@timezone).beginning_of_day.iso8601
    cache_key = "whoop:sleep:#{Date.current.in_time_zone(@timezone)}"
    cached_response = $redis.get(cache_key)

    if cached_response.present?
      sleep_data = JSON.parse(cached_response)
      records = sleep_data['records']
      if records.present?
        return records.find { |record| record['score_state'] == 'SCORED' }
      end
    end

    # Get today's sleep activities
    response = HTTParty.get(
      "#{WHOOP_API_URL}/v2/activity/sleep",
      query: { start: today_start, limit: 10 },
      headers: { "Authorization" => "Bearer #{access_token}" }
    )

    return unless response.success?

    sleep_data = JSON.parse(response.body)
    
    # Cache the entire response
    $redis.setex(cache_key, 5.minutes, response.body)
    
    records = sleep_data['records']
    return if records.blank?

    # Find the first SCORED sleep record
    records.find { |record| record['score_state'] == 'SCORED' }
  rescue StandardError
    nil
  end

  # Fetches recovery data for a specific sleep ID.
  # @param sleep_id [String] The sleep ID to find recovery for.
  # @return [Hash, nil] The recovery record or nil if unavailable.
  def get_recovery_for_sleep(sleep_id)
    return if sleep_id.blank?
    
    access_token = get_access_token
    return if access_token.blank?

    today_start = Time.current.in_time_zone(@timezone).beginning_of_day.iso8601
    cache_key = "whoop:recovery:#{Date.current.in_time_zone(@timezone)}"
    cached_response = $redis.get(cache_key)

    if cached_response.present?
      recovery_data = JSON.parse(cached_response)
      records = recovery_data['records']
      if records.present?
        # Find the recovery that matches our sleep ID and is SCORED
        return records.find do |record| 
          record['sleep_id'] == sleep_id && record['score_state'] == 'SCORED'
        end
      end
    end

    # Get today's recovery data
    response = HTTParty.get(
      "#{WHOOP_API_URL}/v2/recovery",
      query: { start: today_start, limit: 10 },
      headers: { "Authorization" => "Bearer #{access_token}" }
    )

    return unless response.success?

    recovery_data = JSON.parse(response.body)
    
    # Cache the entire response
    $redis.setex(cache_key, 5.minutes, response.body)
    
    records = recovery_data['records']
    return if records.blank?

    # Find the recovery that matches our sleep ID and is SCORED
    records.find do |record| 
      record['sleep_id'] == sleep_id && record['score_state'] == 'SCORED'
    end
  rescue StandardError
    nil
  end

  # Fetches the most recent SCORED strain score from the Whoop API.
  # @return [Float, nil] Strain score (0-21), or nil if unavailable.
  def strain
    access_token = get_access_token
    return if access_token.blank?

    today_start = Time.current.in_time_zone(@timezone).beginning_of_day.iso8601
    cache_key = "whoop:strain:#{Date.current.in_time_zone(@timezone)}"
    cached_response = $redis.get(cache_key)

    if cached_response.present?
      cycle_data = JSON.parse(cached_response)
      records = cycle_data['records']
      if records.present?
        scored_cycle = records.find { |record| record['score_state'] == 'SCORED' }
        return scored_cycle&.dig('score', 'strain')
      end
    end

    # Get today's cycle data
    response = HTTParty.get(
      "#{WHOOP_API_URL}/v2/cycle",
      query: { start: today_start, limit: 10 },
      headers: { "Authorization" => "Bearer #{access_token}" }
    )

    return unless response.success?

    cycle_data = JSON.parse(response.body)
    
    # Cache the entire response
    $redis.setex(cache_key, 5.minutes, response.body)
    
    records = cycle_data['records']
    return if records.blank?

    # Find the first SCORED cycle record
    scored_cycle = records.find { |record| record['score_state'] == 'SCORED' }
    scored_cycle&.dig('score', 'strain')
  rescue StandardError
    nil
  end



  # Gets a valid access token, refreshing if necessary.
  # Handles token rotation by storing new refresh tokens when they're returned.
  # @return [String, nil] Access token or nil if unable to refresh.
  def get_access_token
    return if @client_id.blank? || @client_secret.blank?

    # Check if we have a cached access token
    cached_token = $redis.get('whoop:access_token')
    return cached_token if cached_token.present?

    # Get refresh token from Redis
    refresh_token = $redis.get('whoop:refresh_token')
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

    return unless response.success?

    token_data = JSON.parse(response.body)
    access_token = token_data['access_token']
    new_refresh_token = token_data['refresh_token']
    expires_in = token_data['expires_in'] || 3600

    # Store the new access token with expiration (5 minute buffer)
    cache_duration = [expires_in - 300, 300].max
    $redis.setex('whoop:access_token', cache_duration, access_token)

    # Store the new refresh token (single-use tokens)
    if new_refresh_token.present?
      $redis.set('whoop:refresh_token', new_refresh_token)
    end

    access_token
  rescue StandardError => e
    puts "Error refreshing Whoop token: #{e.message}" if ENV['DEBUG']
    nil
  end
end
