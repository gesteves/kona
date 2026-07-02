# Orchestrates the race-day weather for a featured upcoming event: geocode → forecast
# (within 10 days) → AQI (within 4 days) → SF Bay conditions, each upstream isolated so a
# single failure degrades to a partial card instead of collapsing the widget. Wraps the
# result in an EventWeatherPresenter. (Ported from the former WeatherController#event via
# EventsController#event_weather_for.)
class RaceDayWeather < ApplicationService
  include LocationHelper # in_san_francisco?, which gates the bay-conditions fetch

  # @param event [OpenStruct] A wrapped Contentful event (sys/date/location/coordinates).
  def initialize(event)
    @event = event
  end

  # Builds the race-day weather presenter for the event, or nil when coordinates are
  # unavailable.
  # @return [EventWeatherPresenter, nil]
  def presenter
    lat = @event&.coordinates&.lat
    lon = @event&.coordinates&.lon
    return if lat.blank? || lon.blank?

    gmaps = GoogleMaps.new(lat, lon)
    time_zone = safely("GoogleMaps") { gmaps.time_zone_id } || TimeZoneResolver.default
    country = safely("GoogleMaps") { gmaps.country_code }

    event_datetime = DateTime.parse(@event.date).in_time_zone(time_zone)
    days_until = (event_datetime.to_date - Time.current.in_time_zone(time_zone).to_date).to_i

    weather = safely("WeatherKit") { WeatherKit.new(lat, lon, time_zone, country).data } if country.present? && days_until.between?(0, 10)
    aqi = safely("GoogleAirQuality") { GoogleAirQuality.new(lat, lon, country, "usa_epa_nowcast", event_datetime).aqi } if country.present? && days_until.between?(0, 4)

    location = safely("GoogleMaps") { gmaps.location }
    record = DeepOstruct.wrap(sys: { id: @event.sys&.id }, date: @event.date, location: location, location_label: @event.location, aqi: aqi)
    record.weather = weather

    # Bay conditions only matter for events in San Francisco (the presenter's `bay` applies
    # the same check); skip the Goodspeed fetch everywhere else.
    goodspeed = safely("Goodspeed") { Goodspeed.new.data } if in_san_francisco?(record.location)
    EventWeatherPresenter.new(record, goodspeed: goodspeed)
  end
end
