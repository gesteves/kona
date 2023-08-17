require 'httparty'
require 'redis'

class Spotify
  SPOTIFY_API_URL = 'https://api.spotify.com/v1'

  def initialize
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
  end

  def top_tracks(limit = 5)
    cache_key = "spotify:top_tracks:#{limit}"
    data = @redis.get(cache_key)
    return JSON.parse(data) unless data.nil?

    access_token = get_access_token
    return if access_token.nil?

    headers = { 'Authorization' => "Bearer #{access_token}" }

    ['short_term', 'medium_term', 'long_term'].each do |time_range|
      response = HTTParty.get("#{SPOTIFY_API_URL}/me/top/tracks?time_range=#{time_range}&limit=#{limit}", headers: headers)

      next if response.code != 200

      items = JSON.parse(response.body)['items']
      if !items.empty?
        @redis.setex(cache_key, 86400, items.to_json)
        return items
      end
    end

    []
  end

  def save_data
    File.open('data/spotify.json','w'){ |f| f << top_tracks.to_json }
  end

  private

  def get_access_token
    cache_key = 'spotify:access_token'
    access_token = @redis.get(cache_key)
    return access_token unless access_token.nil?

    access_token = refresh_access_token
    @redis.setex(cache_key, 3600, access_token)
    access_token
  end

  def refresh_access_token
    auth_header = { 'Authorization' => "Basic #{base64_credentials}" }
    body = {
      'grant_type' => 'refresh_token',
      'refresh_token' => ENV['SPOTIFY_REFRESH_TOKEN']
    }

    response = HTTParty.post('https://accounts.spotify.com/api/token', body: body, headers: auth_header)
    return if response.code != 200

    JSON.parse(response.body)['access_token']
  end

  def base64_credentials
    Base64.strict_encode64("#{ENV['SPOTIFY_CLIENT_ID']}:#{ENV['SPOTIFY_CLIENT_SECRET']}")
  end
end
