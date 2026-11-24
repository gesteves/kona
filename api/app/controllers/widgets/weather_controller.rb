module Widgets
  # The current-weather widget in the static site. The cache holds it for five minutes. The
  # race-day weather of an event is in Widgets::EventsController.
  class WeatherController < BaseController
    include ParallelUpstreams

    # Finds the current location of the owner, gets the weather, the air quality, the pollen, the
    # bay data, and the race data, and renders the summary. It renders an empty body when the
    # weather is not available or is old. The view reads each value through @summary.
    def current
      cache_widget(ttl: 5.minutes)

      location = Location.new
      return render_empty if location.latitude.blank?

      # `safely` separates each upstream call. Thus a timeout or a raise gives "no data", and the
      # widget then goes away through render_empty or omits one section. It does not give a 500.
      gmaps = GoogleMaps.new(location.latitude, location.longitude)
      time_zone = time_zone_of(location)
      country = safely("GoogleMaps") { gmaps.country_code }
      weather = safely("WeatherKit") { WeatherKit.new(location.latitude, location.longitude, time_zone, country).data }

      return render_empty unless Forecast.new(weather, time_zone).current?

      # The other six upstream calls do not depend on each other, thus they run at the same time.
      # With a cold cache, that is the difference between the total of their times and the time of
      # the slowest one.
      fetched = in_parallel(
        location: -> { safely("GoogleMaps") { gmaps.location } },
        air_quality: -> { safely("AirQuality") { AirQuality.new(location.latitude, location.longitude, country).data } },
        pollen: -> { safely("GooglePollen") { GooglePollen.new(location.latitude, location.longitude).data } },
        events: -> { safely("Events", []) { Events.new.all } },
        goodspeed: -> { safely("Goodspeed") { Goodspeed.new.data } },
        workouts: -> { planned_workouts(time_zone) }
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
