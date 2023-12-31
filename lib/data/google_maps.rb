require 'httparty'
require 'redis'
require 'active_support/all'

class GoogleMaps
  GOOGLE_MAPS_API_URL = 'https://maps.googleapis.com/maps/api'
  GOOGLE_MAPS_API_KEY = ENV['GOOGLE_MAPS_API_KEY']

  def initialize(latitude, longitude)
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
    @latitude = latitude
    @longitude = longitude
  end

  def time_zone
    data = time_zone_data
    return if data.blank?
    data[:formattedOffset] = format_time_zone_offset(data['rawOffset'])
    data
  end

  def country_code
    data = geocode
    return if data.blank?

    data['results'][0]['address_components'].find { |component| component['types'].include?('country') }['short_name']
  end

  def save_data
    File.open('data/location.json', 'w') { |f| f << geocode.to_json }
    File.open('data/time_zone.json', 'w') { |f| f << time_zone.to_json }
  end

  private

  def geocode
    cache_key = "google_maps:geocoded:#{@latitude}:#{@longitude}"
    data = @redis.get(cache_key)

    return JSON.parse(data) if data.present?

    query = {
      latlng: "#{@latitude},#{@longitude}",
      key: GOOGLE_MAPS_API_KEY,
      language: "en"
    }

    response = HTTParty.get("#{GOOGLE_MAPS_API_URL}/geocode/json", query: query)
    return unless response.success?

    @redis.setex(cache_key, 1.day, response.body)
    JSON.parse(response.body)
  end

  def time_zone_data
    cache_key = "google_maps:time_zone:#{@latitude}:#{@longitude}"
    data = @redis.get(cache_key)

    return JSON.parse(data) if data.present?

    timestamp = Time.now.to_i
    response = HTTParty.get("#{GOOGLE_MAPS_API_URL}/timezone/json?location=#{@latitude},#{@longitude}&timestamp=#{timestamp}&key=#{GOOGLE_MAPS_API_KEY}")
    return unless response.success?

    @redis.setex(cache_key, 1.day, response.body)
    JSON.parse(response.body)
  end

  def format_time_zone_offset(offset_in_seconds)
    offset_minutes = offset_in_seconds.abs / 60
    hours = offset_minutes / 60
    minutes = offset_minutes % 60
    sign = offset_in_seconds < 0 ? "-" : "+"

    "#{sign}#{hours.to_s.rjust(2, '0')}#{minutes.to_s.rjust(2, '0')}"
  end
end
