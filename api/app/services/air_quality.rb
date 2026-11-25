# Finds the current air quality. It uses PurpleAir first, with the nearest sensor, and then the
# Google Air Quality API.
# `data` returns the AQI in an object with dot access, with aqi, category, and description, or nil.
class AirQuality
  include UpstreamIsolation

  def initialize(latitude, longitude, country_code)
    @latitude = latitude
    @longitude = longitude
    @country_code = country_code
  end

  # ⚠️ Each provider has its own `safely`. With `||=` alone, the code uses Google only when
  # PurpleAir returns *nil*. A raise goes past the Google call, and a raise is the one condition
  # that the Google call exists for.
  # @return [OpenStruct, nil]
  def data
    aqi = safely("PurpleAir") { PurpleAir.new(@latitude, @longitude).aqi }
    aqi ||= safely("GoogleAirQuality") { GoogleAirQuality.new(@latitude, @longitude, @country_code).aqi }
    aqi && DeepOstruct.wrap(aqi)
  end
end
