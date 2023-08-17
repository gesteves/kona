require 'httparty'
require 'redis'

module Strava
  STRAVA_API_URL = 'https://www.strava.com/api/v3'

  REDIS = Redis.new(
    host: ENV['REDIS_HOST'] || 'localhost',
    port: ENV['REDIS_PORT'] || 6379,
    username: ENV['REDIS_USERNAME'],
    password: ENV['REDIS_PASSWORD']
  )

  def self.stats
    access_token = get_access_token
    return unless access_token.present?

    headers = {
      "Authorization" => "Bearer #{access_token}",
      "Content-Type" => "application/json"
    }

    response = HTTParty.get("#{STRAVA_API_URL}/athletes/#{ENV['STRAVA_ATHLETE_ID']}/stats", headers: headers)
    stats = JSON.parse(response.body)

    # Rename key to avoid warning about conflict with a built-in Ruby method
    stats.each_key do |k|
      stats[k]['activities'] = stats[k].delete('count') if stats[k].is_a?(Hash) && stats[k]['count'].present?
    end

    File.open('data/strava.json','w'){ |f| f << stats.to_json }
  end

  def self.get_access_token
    access_token = REDIS.get('strava:access_token')
    return access_token if access_token.present?

    refresh_token = REDIS.get('strava:refresh_token') || ENV['STRAVA_REFRESH_TOKEN']
    return unless refresh_token.present?

    refresh_access_token(refresh_token)
  end

  def self.refresh_access_token(refresh_token)
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
    refresh_token = token_info['refresh_token']
    expires_at = token_info['expires_at']
    
    if access_token.present?
      expiration = expires_at - Time.now.to_i
      REDIS.setex('strava:access_token', expiration, access_token)
    end

    if refresh_token.present?
      REDIS.setex('strava:refresh_token', refresh_token)
    end

    access_token
  end
end
