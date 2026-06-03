module Api
  # The home page's "Upcoming Races" section, rendered server-side at request time (instead of
  # baked into the static build) so the featured event, the three-vs-four count, and "Today"
  # labels stay fresh. When an event is featured, its race-day weather renders inline here —
  # replacing the former standalone /api/weather/event widget. Cached for an hour.
  class EventsController < BaseController
    include EventsHelper
    include TimeHelper

    def upcoming
      cache_widget(ttl: 1.hour)

      @events = Events.new.all
      @upcoming = upcoming_races
      return render_empty if @upcoming.blank?

      @featured = @upcoming.first if is_featured?(@upcoming.first)
      @event_weather = event_weather_for(@featured) if @featured

      # On race day the featured event is today's race; give it its own section.
      @todays_race = @featured if @featured && is_today?(@featured)
      @other_races = @upcoming.drop(1) if @todays_race

      render :upcoming
    end

    private

    # Builds the race-day weather presenter for the featured event (geocode → forecast ≤10
    # days → AQI ≤4 days → bay), or nil when coordinates/weather are unavailable. Ported from
    # the former WeatherController#event.
    # @return [EventWeatherPresenter, nil]
    def event_weather_for(event)
      lat = event&.coordinates&.lat
      lon = event&.coordinates&.lon
      return if lat.blank? || lon.blank?

      gmaps = GoogleMaps.new(lat, lon)
      time_zone = gmaps.time_zone_id || TimeZoneResolver.default
      country = gmaps.country_code

      event_datetime = DateTime.parse(event.date).in_time_zone(time_zone)
      days_until = (event_datetime.to_date - Time.current.in_time_zone(time_zone).to_date).to_i

      weather = WeatherKit.new(lat, lon, time_zone, country).data if country.present? && days_until.between?(0, 10)
      aqi = GoogleAirQuality.new(lat, lon, country, "usa_epa_nowcast", event_datetime).aqi if country.present? && days_until.between?(0, 4)
      goodspeed = Goodspeed.new.data

      record = DeepOstruct.wrap(sys: { id: event.sys&.id }, date: event.date, location: gmaps.location, location_label: event.location, aqi: aqi)
      record.weather = weather
      EventWeatherPresenter.new(record, goodspeed: goodspeed)
    end
  end
end
