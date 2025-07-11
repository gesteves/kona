require 'httparty'
require 'active_support/all'

# The GooglePollen class interfaces with the Google Pollen API to fetch pollen data for a location.
class GooglePollen
  GOOGLE_POLLEN_API_URL = 'https://pollen.googleapis.com/v1'

  # Initializes the GooglePollen class with geographical coordinates.
  # @param latitude [Float] The latitude for the location.
  # @param longitude [Float] The longitude for the location.
  # @param days [Integer] The number of days to fetch (default: 1).
  # @return [GooglePollen] The instance of the GooglePollen class.
  def initialize(latitude, longitude, days = 1)
    @latitude = latitude
    @longitude = longitude
    @days = days
    @pollen = get_pollen_forecast
  end

  # Saves the pollen data to a JSON file.
  def save_data
    File.open('data/pollen.json', 'w') { |f| f << @pollen&.deep_transform_keys { |key| key.to_s.underscore }.to_json }
  end

  private

  # Returns the pollen data for the given coordinates.
  # @see https://developers.google.com/maps/documentation/pollen/reference/rest/v1/forecast/lookup#http-request
  # @return [Hash, nil] The pollen data, or nil if fetching fails.
  def get_pollen_forecast
    return if @latitude.blank? || @longitude.blank?
    cache_key = "google:pollen:#{@latitude}:#{@longitude}:#{@days}"
    data = $redis.get(cache_key)

    return JSON.parse(data, symbolize_names: true) if data.present?

    query = {
      'location.latitude': @latitude,
      'location.longitude': @longitude,
      days: @days,
      plantsDescription: 0,
      languageCode: 'en',
      key: ENV['GOOGLE_API_KEY']
    }

    response = HTTParty.get("#{GOOGLE_POLLEN_API_URL}/forecast:lookup", query: query)
    return unless response.success?

    data = JSON.parse(response.body, symbolize_names: true)
    $redis.setex(cache_key, 1.hour, data.to_json) if data.present?
    data
  end
end
