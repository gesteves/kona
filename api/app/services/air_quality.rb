# Finds the current air quality. It uses PurpleAir first, with the nearest sensor, and then the
# Google Air Quality API. The import code of the web app does the same.
# `data` returns the AQI in an object with dot access, with aqi, category, and description, or nil.
class AirQuality
  include UpstreamIsolation

  def initialize(latitude, longitude, country_code)
    @latitude = latitude
    @longitude = longitude
    @country_code = country_code
  end

  # ⚠️ The code separates each provider. With `||=` alone, it uses Google only when PurpleAir returns
  # *nil*. A raise goes past the Google code, thus that code never ran in the one condition that it
  # exists for.
  # @return [OpenStruct, nil]
  def data
    aqi = safely("PurpleAir") { PurpleAir.new(@latitude, @longitude).aqi }
    aqi ||= safely("GoogleAirQuality") { GoogleAirQuality.new(@latitude, @longitude, @country_code).aqi }
    aqi && DeepOstruct.wrap(aqi)
  end
end
