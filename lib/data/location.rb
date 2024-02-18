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
  # Retrieves the location to use for the various condition data (weather, pollen, air quality, etc.)
  # The location can come from a few places:
  # 1. As coordinates in the payload of a Netlify build hook sent from my phone
  #    at regular intervals, which get cached for a couple days.
  # 2. From that cache, if it's still there.
  # 3. From an environment variable, which stores a default location.
  # @return [String, nil] The current location as a "latitude,longitude" string if available.
  def get_current_location
    cache_key = 'location:current'
    cached_location = @redis.get(cache_key)
    payload = parse_incoming_hook_body
    if payload[:latitude].present? && payload[:longitude].present?
      current_location = "#{payload[:latitude]},#{payload[:longitude]}"
      @redis.setex(cache_key, 2.days, current_location)
      current_location
    elsif cached_location.present? && ENV['USE_DEFAULT_LOCATION'].blank?
      cached_location
    else
      ENV['LOCATION']
    end
  end

  # Parses the INCOMING_HOOK_BODY environment variable for latitude and longitude values.
  # @see https://docs.netlify.com/configure-builds/build-hooks/#payload
  # @return [Hash] A hash, which should contain the :latitude and :longitude keys with their respective
  #         values; otherwise returns an empty hash.
  def parse_incoming_hook_body
    JSON.parse(ENV['INCOMING_HOOK_BODY'], symbolize_names: true)
  rescue
    {}
  end
end
