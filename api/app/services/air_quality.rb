# Resolves the current air quality, preferring PurpleAir (nearest sensor) and falling
# back to the Google Air Quality API, mirroring the web app's import logic.
# `data` returns the AQI wrapped for dot-access (aqi/category/description) or nil.
class AirQuality
  include UpstreamIsolation

  def initialize(latitude, longitude, country_code)
    @latitude = latitude
    @longitude = longitude
    @country_code = country_code
  end

  # ⚠️ Each provider is isolated separately. Chaining them with `||=` alone only falls back when
  # PurpleAir returns *nil* — a raise propagates straight past the Google fallback, so the
  # fallback never ran in exactly the case it exists for.
  # @return [OpenStruct, nil]
  def data
    aqi = safely("PurpleAir") { PurpleAir.new(@latitude, @longitude).aqi }
    aqi ||= safely("GoogleAirQuality") { GoogleAirQuality.new(@latitude, @longitude, @country_code).aqi }
    aqi && DeepOstruct.wrap(aqi)
  end
end
