module Api
  # The current-weather widget embedded in the static site: resolves the owner's current
  # location, fetches weather + air quality + pollen + bay + race data, and renders the summary
  # fragment (or an empty body when weather is unavailable/stale). Cached for five minutes.
  # (Per-event race-day weather now lives in Api::EventsController, rendered inline with the
  # featured upcoming race.)
  class WeatherController < BaseController
    include WeatherHelper
    include TimeHelper # weather_data_is_current? → rest_of_day_forecast → is_evening? → current_time

    # Renders the current-weather widget markup embedded into the static site. Resolves the
    # owner's current location, fetches weather + air quality + pollen + bay + race data, and
    # renders the summary (or an empty body when weather is unavailable/stale, which tells the
    # live-update controller to remove the placeholder so the widget collapses).
    def current
      cache_widget(ttl: 5.minutes)

      location = Location.new
      return render_empty if location.latitude.blank?

      # Each upstream is isolated (safely) so a timeout or raise degrades to "no data" — the
      # widget then collapses via render_empty or omits a section, instead of 500ing.
      gmaps = GoogleMaps.new(location.latitude, location.longitude)
      @time_zone = safely("GoogleMaps") { gmaps.time_zone_id } || TimeZoneResolver.default
      @location = DeepOstruct.wrap(safely("GoogleMaps") { gmaps.location })
      country = safely("GoogleMaps") { gmaps.country_code }
      @weather = safely("WeatherKit") { WeatherKit.new(location.latitude, location.longitude, @time_zone, country).data }

      return render_empty unless weather_data_is_current?(@weather)

      @air_quality = safely("AirQuality") { AirQuality.new(location.latitude, location.longitude, country).data }
      @pollen = safely("GooglePollen") { GooglePollen.new(location.latitude, location.longitude).data }
      @events = safely("Events", []) { Events.new.all }
      @goodspeed = safely("Goodspeed") { Goodspeed.new.data }
      @workouts = safely("TrainerRoad") { TrainerRoad.new(@time_zone).workouts } || []

      @summary = WeatherSummaryPresenter.new(
        weather: @weather,
        location: @location,
        air_quality: @air_quality,
        pollen: @pollen,
        events: @events,
        goodspeed: @goodspeed,
        workouts: @workouts,
        time_zone: @time_zone
      )

      render :current
    end
  end
end
