# Resolves the current air quality, preferring PurpleAir (nearest sensor) and falling
# back to the Google Air Quality API, mirroring the web app's import logic.
# `data` returns the AQI wrapped for dot-access (aqi/category/description) or nil.
class AirQuality
  def initialize(latitude, longitude, country_code)
    @latitude = latitude
    @longitude = longitude
    @country_code = country_code
  end

  # @return [OpenStruct, nil]
  def data
    aqi = PurpleAir.new(@latitude, @longitude).aqi
    aqi ||= GoogleAirQuality.new(@latitude, @longitude, @country_code).aqi
    aqi && DeepOstruct.wrap(aqi)
  end
end
