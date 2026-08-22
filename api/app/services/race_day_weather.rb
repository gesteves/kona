# Controls the race-day weather of a featured upcoming event: the geocode, then the forecast for a
# race in the next 10 days, then the AQI for a race in the next 4 days, then the SF Bay conditions.
# Each upstream call is separate, thus one failure gives a card with some data and does not remove
# the widget. It puts the result in an EventWeatherPresenter. This code came from the
# WeatherController#event of the past, through EventsController#event_weather_for.
class RaceDayWeather < ApplicationService
  include LocationHelper # in_san_francisco?, which gates the bay-conditions fetch

  # @param event [OpenStruct] A Contentful event object, with sys, date, location, and
  #   coordinates.
  def initialize(event)
    @event = event
  end

  # Makes the race-day weather presenter of the event, or nil when the coordinates are not
  # available.
  # @return [EventWeatherPresenter, nil]
  def presenter
    lat = @event&.coordinates&.lat
    lon = @event&.coordinates&.lon
    return if lat.blank? || lon.blank?
    # Contentful can hold an event with no date. Give a smaller result and do not stop the widget.
    return if @event.date.blank?

    gmaps = GoogleMaps.new(lat, lon)
    time_zone = safely("GoogleMaps") { gmaps.time_zone_id } || TimeZoneResolver.default
    country = safely("GoogleMaps") { gmaps.country_code }

    event_datetime = begin
      DateTime.parse(@event.date).in_time_zone(time_zone)
    rescue ArgumentError, TypeError
      return
    end
    days_until = (event_datetime.to_date - Time.current.in_time_zone(time_zone).to_date).to_i

    weather = safely("WeatherKit") { WeatherKit.new(lat, lon, time_zone, country).data } if country.present? && days_until.between?(0, 10)
    aqi = safely("GoogleAirQuality") { GoogleAirQuality.new(lat, lon, country, "usa_epa_nowcast", event_datetime).aqi } if country.present? && days_until.between?(0, 4)

    location = safely("GoogleMaps") { gmaps.location }
    record = DeepOstruct.wrap(sys: { id: @event.sys&.id }, date: @event.date, location: location, location_label: @event.location, aqi: aqi)
    record.weather = weather

    # The bay conditions apply to an event in San Francisco only, and the `bay` of the presenter
    # does the same check. Do not call Goodspeed for another location.
    goodspeed = safely("Goodspeed") { Goodspeed.new.data } if in_san_francisco?(record.location)
    EventWeatherPresenter.new(record, goodspeed: goodspeed)
  end
end
