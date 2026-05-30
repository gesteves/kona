module Api
  # Per-event race-day weather, fetched live by the static site (keyed by Contentful event
  # ID) instead of baked into the event at build time. Looks the event up in Contentful,
  # geocodes it, fetches the forecast (≤10 days out) + AQI (≤4 days out) + bay data, and
  # renders the event-weather fragment. Cached for an hour (the forecast is days out).
  class WeatherController < ActionController::Base
    # Renders the current-weather widget markup embedded into the static site. Resolves the
    # owner's current location, fetches weather + air quality + pollen + bay + race data, and
    # renders the summary (or an empty body when weather is unavailable/stale, so the
    # live-update controller leaves the existing markup in place).
    def current
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

      render :current, layout: false
    end

    def event
      expires_in 1.hour, public: true, stale_while_revalidate: 1.hour

      record = Events.new.find(params[:id])
      lat = record&.coordinates&.lat
      lon = record&.coordinates&.lon
      return render(plain: "", layout: false) if lat.blank? || lon.blank?

      gmaps = GoogleMaps.new(lat, lon)
      @time_zone = gmaps.time_zone_id || ENV.fetch("TIME_ZONE", "America/Denver")
      country = gmaps.country_code

      event_datetime = DateTime.parse(record.date).in_time_zone(@time_zone)
      days_until = (event_datetime.to_date - Time.current.in_time_zone(@time_zone).to_date).to_i

      weather = WeatherKit.new(lat, lon, @time_zone, country).data if country.present? && days_until.between?(0, 10)
      aqi = GoogleAirQuality.new(lat, lon, country, "usa_epa_nowcast", event_datetime).aqi if country.present? && days_until.between?(0, 4)

      @goodspeed = Goodspeed.new.data
      @event = DeepOstruct.wrap(sys: { id: record.sys&.id }, date: record.date, location: gmaps.location, location_label: record.location, aqi: aqi)
      @event.weather = weather

      render :event, layout: false
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
end
