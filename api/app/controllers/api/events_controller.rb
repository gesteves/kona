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
      @event_weather = RaceDayWeather.new(@featured).presenter if @featured

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
  end
end
