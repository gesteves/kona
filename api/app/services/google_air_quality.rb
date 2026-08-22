# Gets the air quality from the Google Air Quality API. The app uses it when PurpleAir has no sensor
# near the location, for example outside the USA. `aqi` returns { aqi:, category:, description: }, or
# nil.
class GoogleAirQuality < ApplicationService
  include GoogleApi

  GOOGLE_AQI_API_URL = "https://airquality.googleapis.com/v1"

  # The forecast endpoint of Google covers the next 96 hours, that is, 4 days. A dateTime after that
  # gives a 400 with "The specified time period is not supported". Stop before such a request.
  FORECAST_MAX_HORIZON = 96.hours

  def initialize(latitude, longitude, country_code, aqi_code = "usa_epa_nowcast", datetime = nil)
    @latitude = latitude
    @longitude = longitude
    @country_code = country_code
    @aqi_code = aqi_code
    @datetime = datetime
  end

  def aqi
    return @aqi if defined?(@aqi)
    @aqi = get_aqi
  end

  private

  def get_aqi
    data = (@datetime.nil? || @datetime <= Time.current) ? get_current_conditions : get_forecast
    return if data.blank?

    data = data[:hourlyForecasts].first if data[:hourlyForecasts].present?

    # Use the local index only, which is the US EPA NowCast. The Universal AQI of Google (uaqi) uses
    # a 0 to 100 scale in the other direction: 0 is the worst and 100 is the best, which is the
    # opposite of the US EPA scale. With our EPA icon and label, that number would be incorrect. If
    # the response has no local index, return nil, thus the widget removes the AQI line and shows no
    # incorrect number.
    result = data[:indexes]&.find { |i| i[:code] == @aqi_code }
    return if result.blank?

    {
      aqi: result[:aqi],
      category: result[:category].gsub(/\s?air quality\s?/i, " ").strip,
      description: result[:category]
    }
  end

  # @see https://developers.google.com/maps/documentation/air-quality/reference/rest/v1/currentConditions/lookup
  def get_current_conditions
    return unless coordinates?
    return if @country_code.blank?

    cached_json("google:aqi:#{@latitude}:#{@longitude}:#{@country_code}:#{@aqi_code}", expires_in: 5.minutes) do
      body = {
        location: { latitude: @latitude, longitude: @longitude },
        languageCode: "en",
        extraComputations: [ "LOCAL_AQI" ],
        customLocalAqis: [ { regionCode: @country_code, aqi: @aqi_code } ]
      }
      post_aqi("currentConditions:lookup", body)
    end
  end

  # @see https://developers.google.com/maps/documentation/air-quality/reference/rest/v1/forecast/lookup
  def get_forecast
    return unless coordinates?
    return if @country_code.blank? || @datetime.blank?
    return if @datetime > Time.current + FORECAST_MAX_HORIZON

    cache_key = "google:aqi:forecast:#{@latitude}:#{@longitude}:#{@country_code}:#{@aqi_code}:#{@datetime.iso8601}"
    cached_json(cache_key, expires_in: 5.minutes) do
      body = {
        location: { latitude: @latitude, longitude: @longitude },
        dateTime: @datetime.iso8601,
        languageCode: "en",
        extraComputations: [ "LOCAL_AQI" ],
        customLocalAqis: [ { regionCode: @country_code, aqi: @aqi_code } ]
      }
      post_aqi("forecast:lookup", body)
    end
  end

  def post_aqi(endpoint, body)
    post_json(
      "#{GOOGLE_AQI_API_URL}/#{endpoint}",
      query: { key: google_api_key },
      body: body.to_json,
      headers: { "Content-Type": "application/json" }
    )
  end
end
