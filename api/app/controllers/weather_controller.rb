# Renders the weather widget markup embedded into the static site. Resolves the owner's
# current location, fetches weather + air quality + pollen + bay + race data, and renders
# the summary (or an empty body when weather is unavailable/stale, so the live-update
# controller leaves the existing markup in place).
class WeatherController < ActionController::Base
  def show
    expires_in 5.minutes, public: true, stale_while_revalidate: 1.hour

    location = Location.new
    return render(plain: "", layout: false) if location.latitude.blank?

    gmaps = GoogleMaps.new(location.latitude, location.longitude)
    @time_zone = gmaps.time_zone_id || ENV.fetch("TIME_ZONE", "America/Denver")
    @location = DeepOstruct.wrap(gmaps.location)
    @weather = WeatherKit.new(location.latitude, location.longitude, @time_zone, gmaps.country_code).data

    return render(plain: "", layout: false) unless weather_current?(@weather)

    @air_quality = AirQuality.new(location.latitude, location.longitude, gmaps.country_code).data
    @pollen = GooglePollen.new(location.latitude, location.longitude).data
    @events = Events.new.all
    @goodspeed = Goodspeed.new.data
    @workouts = TrainerRoad.new(@time_zone).workouts || []

    render :show, layout: false
  end

  private

  # Mirrors WeatherHelper#weather_data_is_current? without pulling the view helpers into the
  # controller: current conditions present and a daily forecast covering right now.
  def weather_current?(weather)
    return false if weather.blank?
    now = Time.now
    today = weather.forecast_daily&.days&.find do |d|
      d.rest_of_day_forecast.present? && Time.parse(d.forecast_start) <= now && Time.parse(d.forecast_end) >= now
    end
    weather.current_weather.present? && today.present?
  end
end
