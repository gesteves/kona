require 'httparty'
require 'redis'
require 'active_support/all'

class Swarm
  FOURSQUARE_API_URL = 'https://api.foursquare.com/v2'

  def initialize
    @access_token = ENV['FOURSQUARE_ACCESS_TOKEN']
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
    @time_zone = ENV['DEFAULT_TIMEZONE'] || 'America/Denver'
  end

  def recent_checkin_location
    current_time = Time.now.in_time_zone(@time_zone)
    latest = current_time.beginning_of_day
    earliest = latest - 2.days
    data = get_checkins
    checkin = data.dig('response', 'checkins', 'items')&.find { |c| c['createdAt'] >= earliest.to_i && c['createdAt'] < latest.to_i }
    latitude = checkin&.dig('venue', 'location', 'lat')
    longitude = checkin&.dig('venue', 'location', 'lng')
    { latitude: latitude, longitude: longitude }.compact
  end

  private

  def get_checkins
    v = '20230818'
    cache_key = "swarm:checkins:#{v}"
    data = @redis.get(cache_key)

    return JSON.parse(data) if data.present?

    query = {
      oauth_token: @access_token,
      v: v
    }

    response = HTTParty.get("#{FOURSQUARE_API_URL}/users/self/checkins", query: query)
    return unless response.success?

    @redis.setex(cache_key, 1.hour, response.body)
    JSON.parse(response.body)
  end
end
