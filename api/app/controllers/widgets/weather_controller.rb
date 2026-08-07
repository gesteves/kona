module Widgets
  # The current-weather widget embedded in the static site: resolves the owner's current
  # location, fetches weather + air quality + pollen + bay + race data, and renders the summary
  # fragment (or an empty body when weather is unavailable/stale). Cached for five minutes.
  # (Per-event race-day weather now lives in Widgets::EventsController, rendered inline with the
  # featured upcoming race.)
  class WeatherController < BaseController
    include ParallelUpstreams

    # Renders the current-weather widget markup embedded into the static site. Resolves the
    # owner's current location, fetches weather + air quality + pollen + bay + race data, and
    # renders the summary (or an empty body when weather is unavailable/stale, which tells the
    # live-update controller to remove the placeholder so the widget collapses). The view
    # consumes everything through @summary.
    def current
      cache_widget(ttl: 5.minutes)

      location = Location.new
      return render_empty if location.latitude.blank?

      # Each upstream is isolated (safely) so a timeout or raise degrades to "no data" — the
      # widget then collapses via render_empty or omits a section, instead of 500ing.
      gmaps = GoogleMaps.new(location.latitude, location.longitude)
      time_zone = safely("GoogleMaps") { gmaps.time_zone_id } || TimeZoneResolver.default
      country = safely("GoogleMaps") { gmaps.country_code }
      weather = safely("WeatherKit") { WeatherKit.new(location.latitude, location.longitude, time_zone, country).data }

      return render_empty unless helpers.weather_data_is_current?(weather, time_zone)

      # The remaining six upstreams don't depend on each other, so they run concurrently: cold,
      # this is the difference between the sum of their latencies and the slowest one.
      fetched = in_parallel(
        location: -> { safely("GoogleMaps") { gmaps.location } },
        air_quality: -> { safely("AirQuality") { AirQuality.new(location.latitude, location.longitude, country).data } },
        pollen: -> { safely("GooglePollen") { GooglePollen.new(location.latitude, location.longitude).data } },
        events: -> { safely("Events", []) { Events.new.all } },
        goodspeed: -> { safely("Goodspeed") { Goodspeed.new.data } },
        workouts: -> { safely("TrainerRoad", []) { TrainerRoad.new(time_zone).workouts } }
      )

      @summary = WeatherSummaryPresenter.new(
        weather: weather,
        location: DeepOstruct.wrap(fetched[:location]),
        air_quality: fetched[:air_quality],
        pollen: fetched[:pollen],
        events: fetched[:events] || [],
        goodspeed: fetched[:goodspeed],
        workouts: fetched[:workouts] || [],
        time_zone: time_zone
      )

      render :current
    end
  end
end
