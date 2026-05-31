# Fetches the pollen forecast from the Google Pollen API. The raw response is cached in
# Redis for an hour. `data` returns it wrapped for dot-access (keys snake_cased), or nil.
class GooglePollen < ApplicationService
  GOOGLE_POLLEN_API_URL = "https://pollen.googleapis.com/v1"

  def initialize(latitude, longitude, days = 1)
    @latitude = latitude
    @longitude = longitude
    @days = days
  end

  # @return [OpenStruct, nil]
  def data
    return @data if defined?(@data)
    pollen = underscore_keys(get_pollen_forecast)
    @data = pollen && DeepOstruct.wrap(pollen)
  end

  private

  # @see https://developers.google.com/maps/documentation/pollen/reference/rest/v1/forecast/lookup
  def get_pollen_forecast
    return if @latitude.blank? || @longitude.blank?

    cached_json("google:pollen:#{@latitude}:#{@longitude}:#{@days}", expires_in: 1.hour) do
      query = {
        "location.latitude": @latitude,
        "location.longitude": @longitude,
        days: @days,
        plantsDescription: 0,
        languageCode: "en",
        key: ENV["GOOGLE_API_KEY"]
      }
      get_json("#{GOOGLE_POLLEN_API_URL}/forecast:lookup", query: query)
    end
  end
end
