module Api
  # Per-event race-day weather, fetched live by the static site (keyed by Contentful event
  # ID) instead of baked into the event at build time. Looks the event up in Contentful,
  # geocodes it, fetches the forecast (≤10 days out) + AQI (≤4 days out) + bay data, and
  # renders the event-weather fragment. Cached for an hour (the forecast is days out).
  class WeatherController < ActionController::Base
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
      @event = DeepOstruct.wrap(sys: { id: record.sys&.id }, date: record.date, location: gmaps.location, aqi: aqi)
      @event.weather = weather

      render :event, layout: false
    end
  end
end
