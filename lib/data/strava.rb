require 'httparty'
require 'redis'
require 'active_support/all'

class Strava
  STRAVA_API_URL = 'https://www.strava.com/api/v3'

  def initialize
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
    @athlete_id = ENV['STRAVA_ATHLETE_ID']
  end

  def stats
    cache_key = "strava:stats:#{@athlete_id}"
    data = @redis.get(cache_key)

    return JSON.parse(data) if data.present?

    access_token = get_access_token
    return if access_token.blank?

    headers = {
      "Authorization" => "Bearer #{access_token}",
      "Content-Type" => "application/json"
    }

    response = HTTParty.get("#{STRAVA_API_URL}/athletes/#{@athlete_id}/stats", headers: headers)
    return unless response.success?

    stats = JSON.parse(response.body)

    # Rename key to avoid warning about conflict with a built-in Ruby method
    stats.each_key do |k|
      stats[k]['activities'] = stats[k].delete('count') if stats[k].is_a?(Hash) && stats[k]['count'].present?
    end

    @redis.setex(cache_key, 5.minutes, stats.to_json)

    stats
  end

  def save_data
    data = {
      stats: stats
    }
    File.open('data/strava.json', 'w') { |f| f << data.to_json }
  end

  private

  def get_access_token
    access_token = @redis.get('strava:access_token')
    return access_token if access_token.present?

    refresh_token = @redis.get('strava:refresh_token') || ENV['STRAVA_REFRESH_TOKEN']
    return if refresh_token.blank?

    refresh_access_token(refresh_token)
  end

  def refresh_access_token(refresh_token)
    client_id = ENV['STRAVA_CLIENT_ID']
    client_secret = ENV['STRAVA_CLIENT_SECRET']

    response = HTTParty.post("#{STRAVA_API_URL}/oauth/token", body: {
      client_id: client_id,
      client_secret: client_secret,
      refresh_token: refresh_token,
      grant_type: 'refresh_token'
    })

    token_info = JSON.parse(response.body)
    access_token = token_info['access_token']
    new_refresh_token = token_info['refresh_token']
    expires_at = token_info['expires_at']

    if access_token.present?
      expiration = expires_at - Time.now.to_i
      @redis.setex('strava:access_token', expiration, access_token)
    end

    if new_refresh_token.present?
      @redis.set('strava:refresh_token', new_refresh_token)
    end

    access_token
  end
end
