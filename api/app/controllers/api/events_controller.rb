module Api
  # The home page's "Upcoming Races" section, rendered server-side at request time (instead of
  # baked into the static build) so the featured event, the three-vs-four count, and "Today"
  # labels stay fresh. When an event is featured, its race-day weather renders inline here —
  # replacing the former standalone /api/weather/event widget. Cached for an hour.
  class EventsController < BaseController
    include EventsHelper
    include TimeHelper

    def upcoming
      # Edge SWR kept at a day (vs. the one-hour default): the upcoming-races list changes
      # rarely, so serving a stale copy while revalidating costs nothing.
      cache_widget(ttl: 1.hour, edge_stale_while_revalidate: 1.day)

      @events = Events.new.all
      @upcoming = upcoming_races
      return render_empty if @upcoming.blank?

      @featured = @upcoming.first if is_featured?(@upcoming.first)
      @event_weather = event_weather_for(@featured) if @featured

      # On race day the featured event is today's race; give it its own section.
      @todays_race = @featured if @featured && is_today?(@featured)

      # An upcoming (not-today) featured event only earns the expanded treatment when we actually
      # have race-day weather to show. The featured window (is_close?, in the owner's timezone) and
      # the weather-fetch window (days_until, computed in the event's own geocoded timezone) can
      # disagree at the 10-day boundary, which would otherwise leave a featured card carrying an
      # empty "Race Day Weather" block for an event that's effectively more than 10 days out. When
      # the weather's missing, demote it to a regular upcoming race (and trim back to the
      # non-featured count). Today's race keeps its section regardless — it's race day.
      if @featured && !@todays_race && @event_weather&.forecast.blank?
        @featured = nil
        @event_weather = nil
        @upcoming = @upcoming.take(3)
      end

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
