require "httparty"

# Fetches air quality from the Google Air Quality API (the fallback when PurpleAir has
# no nearby sensor, e.g. outside the US). `aqi` returns { aqi:, category:, description: }
# or nil.
class GoogleAirQuality
  attr_reader :aqi
  GOOGLE_AQI_API_URL = "https://airquality.googleapis.com/v1"

  def initialize(latitude, longitude, country_code, aqi_code = "usa_epa_nowcast", datetime = nil)
    @latitude = latitude
    @longitude = longitude
    @country_code = country_code
    @aqi_code = aqi_code
    @datetime = datetime
    @aqi = get_aqi
  end

  private

  def get_aqi
    data = (@datetime.nil? || @datetime <= Time.current) ? get_current_conditions : get_forecast
    return if data.blank?

    data = data[:hourlyForecasts].first if data[:hourlyForecasts].present?

    result = data[:indexes]&.find { |i| i[:code] == @aqi_code }
    result ||= data[:indexes]&.find { |i| i[:code] == "uaqi" }
    return if result.blank?

    {
      aqi: result[:aqi],
      category: result[:category].gsub(/\s?air quality\s?/i, " ").strip,
      description: result[:category]
    }
  end

  # @see https://developers.google.com/maps/documentation/air-quality/reference/rest/v1/currentConditions/lookup
  def get_current_conditions
    return if @latitude.blank? || @longitude.blank? || @country_code.blank?
    cache_key = "google:aqi:#{@latitude}:#{@longitude}:#{@country_code}:#{@aqi_code}"
    cached = $redis.get(cache_key)
    return JSON.parse(cached, symbolize_names: true) if cached.present?

    body = {
      location: { latitude: @latitude, longitude: @longitude },
      languageCode: "en",
      extraComputations: ["LOCAL_AQI"],
      customLocalAqis: [{ regionCode: @country_code, aqi: @aqi_code }]
    }

    response = HTTParty.post("#{GOOGLE_AQI_API_URL}/currentConditions:lookup", query: { key: ENV["GOOGLE_API_KEY"] }, body: body.to_json, headers: { "Content-Type": "application/json" })
    return unless response.success?

    $redis.setex(cache_key, 5.minutes, response.body)
    JSON.parse(response.body, symbolize_names: true)
  end

  # @see https://developers.google.com/maps/documentation/air-quality/reference/rest/v1/forecast/lookup
  def get_forecast
    return if @latitude.blank? || @longitude.blank? || @country_code.blank? || @datetime.blank?
    cache_key = "google:aqi:forecast:#{@latitude}:#{@longitude}:#{@country_code}:#{@aqi_code}:#{@datetime.iso8601}"
    cached = $redis.get(cache_key)
    return JSON.parse(cached, symbolize_names: true) if cached.present?

    body = {
      location: { latitude: @latitude, longitude: @longitude },
      dateTime: @datetime.iso8601,
      languageCode: "en",
      extraComputations: ["LOCAL_AQI"],
      customLocalAqis: [{ regionCode: @country_code, aqi: @aqi_code }]
    }

    response = HTTParty.post("#{GOOGLE_AQI_API_URL}/forecast:lookup", query: { key: ENV["GOOGLE_API_KEY"] }, body: body.to_json, headers: { "Content-Type": "application/json" })
    return unless response.success?

    $redis.setex(cache_key, 5.minutes, response.body)
    JSON.parse(response.body, symbolize_names: true)
  end
end
