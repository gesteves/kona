require "httparty"

# Fetches the pollen forecast from the Google Pollen API. The raw response is cached in
# Redis for an hour. `data` returns it wrapped for dot-access (keys snake_cased), or nil.
class GooglePollen
  GOOGLE_POLLEN_API_URL = "https://pollen.googleapis.com/v1"

  def initialize(latitude, longitude, days = 1)
    @latitude = latitude
    @longitude = longitude
    @days = days
  end

  # @return [OpenStruct, nil]
  def data
    return @data if defined?(@data)
    pollen = get_pollen_forecast&.deep_transform_keys { |key| key.to_s.underscore.to_sym }
    @data = pollen && DeepOstruct.wrap(pollen)
  end

  private

  # @see https://developers.google.com/maps/documentation/pollen/reference/rest/v1/forecast/lookup
  def get_pollen_forecast
    return if @latitude.blank? || @longitude.blank?
    cache_key = "google:pollen:#{@latitude}:#{@longitude}:#{@days}"
    cached = $redis.get(cache_key)
    return JSON.parse(cached, symbolize_names: true) if cached.present?

    query = {
      "location.latitude": @latitude,
      "location.longitude": @longitude,
      days: @days,
      plantsDescription: 0,
      languageCode: "en",
      key: ENV["GOOGLE_API_KEY"]
    }

    response = HTTParty.get("#{GOOGLE_POLLEN_API_URL}/forecast:lookup", query: query)
    return unless response.success?

    parsed = JSON.parse(response.body, symbolize_names: true)
    $redis.setex(cache_key, 1.hour, parsed.to_json) if parsed.present?
    parsed
  end
end
