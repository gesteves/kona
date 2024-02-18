require 'redis'
require 'active_support/all'

# Represents a geographic location with latitude and longitude attributes.
class Location
  attr_reader :latitude, :longitude

  # Initializes the Location instance by fetching the current location from available sources.
  def initialize
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
    location = get_current_location
    @latitude, @longitude = location.split(',').map(&:to_f) if location.present?
  end

  private
  # Retrieves the current location from either the INCOMING_HOOK_BODY environment variable,
  # a Redis cache, or the LOCATION environment variable, in that order of priority.
  #
  # The method ensures that the most up-to-date and valid location is used, preferring
  # real-time data from the INCOMING_HOOK_BODY, then cached data, and finally a preset
  # environment variable if no other source is available.
  #
  # @return [String, nil] The current location as a "latitude,longitude" string if available;
  #         otherwise, returns nil if no valid location data can be found or parsed.
  def get_current_location
    cache_key = 'location:current'
    cached_location = @redis.get(cache_key)
    payload = parse_incoming_hook_body
    if payload[:latitude].present? && payload[:longitude].present?
      current_location = "#{payload[:latitude]},#{payload[:longitude]}"
      @redis.setex(cache_key, 2.days, current_location)
      current_location
    elsif cached_location.present? && ENV['CONTEXT'] != 'dev'
      cached_location
    else
      ENV['LOCATION']
    end
  end

  # Parses the INCOMING_HOOK_BODY environment variable for latitude and longitude values.
  #
  # @return [Hash] A hash containing :latitude and :longitude keys with their respective
  #         values if parsing is successful; an empty hash is returned if parsing fails
  #         or if the necessary values are not present.
  def parse_incoming_hook_body
    JSON.parse(ENV['INCOMING_HOOK_BODY'], symbolize_names: true)
  rescue
    {}
  end
end
