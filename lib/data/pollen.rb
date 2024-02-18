require 'httparty'
require 'redis'
require 'active_support/all'

# The Pollen class interfaces with the Google Pollen API to fetch pollen data for a location.
class Pollen
  GOOGLE_POLLEN_API_URL = 'https://pollen.googleapis.com/v1'

  # Initializes the Pollen class with geographical coordinates.
  # @param latitude [Float] The latitude for the location.
  # @param longitude [Float] The longitude for the location.
  # @return [GoogleMaps] The instance of the Pollen class.
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

  # Retrieves the pollen forecast for the specified coordinates.
  # @return [Hash, nil] The pollen data, or nil if fetching fails.
  def pollen
    data = pollen_forecast
    return if data.blank?

    data['dailyInfo'][0]['pollenTypeInfo']
  end

  # Saves the geocode and time zone data to JSON files.
  def save_data
    File.open('data/pollen.json', 'w') { |f| f << pollen.to_json }
  end

  private

  # Returns the pollen data for the given coordinates.
  # @see https://developers.google.com/maps/documentation/pollen/reference/rest/v1/forecast/lookup#http-request
  # @return [Hash, nil] The pollen data, or nil if fetching fails.
  def pollen_forecast
    return if @latitude.blank? || @longitude.blank?
    cache_key = "google:pollen:#{@latitude}:#{@longitude}"
    data = @redis.get(cache_key)

    return JSON.parse(data) if data.present?

    query = {
      'location.latitude': @latitude,
      'location.longitude': @longitude,
      days: 1,
      plantsDescription: 0,
      languageCode: 'en',
      key: ENV['GOOGLE_API_KEY']
    }

    response = HTTParty.get("#{GOOGLE_POLLEN_API_URL}/forecast:lookup", query: query)
    return unless response.success?

    @redis.setex(cache_key, 1.hour, response.body)
    JSON.parse(response.body)
  end
end
