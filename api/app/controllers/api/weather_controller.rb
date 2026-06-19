module Api
  # The current-weather widget embedded in the static site: resolves the owner's current
  # location, fetches weather + air quality + pollen + bay + race data, and renders the summary
  # fragment (or an empty body when weather is unavailable/stale). Cached for five minutes.
  # (Per-event race-day weather now lives in Api::EventsController, rendered inline with the
  # featured upcoming race.)
  class WeatherController < BaseController
    include WeatherHelper

    # Renders the current-weather widget markup embedded into the static site. Resolves the
    # owner's current location, fetches weather + air quality + pollen + bay + race data, and
    # renders the summary (or an empty body when weather is unavailable/stale, which tells the
    # live-update controller to remove the placeholder so the widget collapses).
    def current
      cache_widget(ttl: 5.minutes)

      location = Location.new
      return render_empty if location.latitude.blank?

      gmaps = GoogleMaps.new(location.latitude, location.longitude)
      @time_zone = gmaps.time_zone_id || TimeZoneResolver.default
      @location = DeepOstruct.wrap(gmaps.location)
      @weather = WeatherKit.new(location.latitude, location.longitude, @time_zone, gmaps.country_code).data

      return render_empty unless weather_data_is_current?(@weather)

      @air_quality = AirQuality.new(location.latitude, location.longitude, gmaps.country_code).data
      @pollen = GooglePollen.new(location.latitude, location.longitude).data
      @events = Events.new.all
      @goodspeed = Goodspeed.new.data
      @workouts = TrainerRoad.new(@time_zone).workouts || []

      render :current
    end
  end
end
