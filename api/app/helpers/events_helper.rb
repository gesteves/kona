module EventsHelper
  # Whether the event is today, in the current location's timezone.
  def is_today?(event)
    return false if event.blank?
    event_date = Time.parse(event.date).in_time_zone(location_time_zone)
    event_date.to_date == current_time.to_date
  end

  # Today's race, if any (an event that's today and confirmed).
  # @return [OpenStruct, nil]
  def todays_race
    return if @events.blank?
    @events.find { |e| is_today?(e) && e.going }
  end

  # Whether today is a race day.
  def is_race_day?
    todays_race.present?
  end

  # Whether the event is happening right now. Confirmed (going) events only. Prefers the event's
  # own race-day weather — the sunrise..sunset window for the event's date, at the event's
  # location — which we already fetch for the featured race; covering "now" means it's both the
  # event's day and daytime there. Falls back to today-and-daytime in the owner's current
  # timezone when that weather (and thus its sun times) isn't available.
  def is_in_progress?(event, event_weather = nil)
    return false if event.blank? || !event.going
    window = event_daylight_window(event_weather)
    return window.cover?(Time.current) if window
    is_daytime? && is_today?(event)
  end

  # The event-day daylight window (sunrise..sunset) drawn from the featured race's already-fetched
  # weather, or nil when those sun times aren't available. The forecast day covers the event's
  # date and the sun times are absolute instants, so callers compare the current time against this
  # window without converting timezones.
  def event_daylight_window(event_weather = nil)
    sunrise = event_weather&.sunrise
    sunset = event_weather&.sunset
    return if sunrise.blank? || sunset.blank?
    Time.parse(sunrise)..Time.parse(sunset)
  end

  # The daytime forecast for the event's date, used by the per-event weather view.
  def event_forecast(event)
    event_forecast_day(event)&.daytime_forecast
  end

  # The forecast day covering the event's date (carries sunrise/sunset too).
  def event_forecast_day(event)
    return nil if event.blank? || event.weather&.forecast_daily&.days.blank?
    event_date = Date.parse(event.date)
    event.weather.forecast_daily.days.find do |day|
      day_start = Date.parse(day.forecast_start)
      day_end = Date.parse(day.forecast_end)
      event_date >= day_start && event_date < day_end
    end
  end

  # The upcoming races to show: future-or-today confirmed events, soonest first. When the next
  # one is within 10 days it's "featured" (expanded card + race-day weather) and we show four;
  # otherwise three. Mirrors the static site's build-time helper, reading @events. Memoized —
  # it's consulted several times per request (selection, is_next?, the view) and each
  # computation re-parses and re-sorts every event.
  def upcoming_races
    @upcoming_races ||= if @events.blank?
      []
    else
      upcoming = @events
        .select { |e| e.going && Time.parse(e.date).in_time_zone(location_time_zone).beginning_of_day >= current_time.beginning_of_day }
        .sort_by { |e| Time.parse(e.date) }
      next_event = upcoming.first
      featured = next_event.present? && is_close?(next_event)
      upcoming.take(featured ? 4 : 3)
    end
  end

  # Whether the event is today or within the next 10 days.
  def is_close?(event)
    return false if event.blank?
    event_date = Time.parse(event.date).in_time_zone(location_time_zone).to_date
    event_date >= current_time.to_date && event_date <= 10.days.from_now.to_date
  end

  # Whether the event is the next upcoming race.
  def is_next?(event)
    return false if event.blank?
    event.sys&.id == upcoming_races.first&.sys&.id
  end

  # Whether the event gets the featured treatment (the next race, and within 10 days).
  def is_featured?(event)
    return false if event.blank?
    is_close?(event) && is_next?(event)
  end

  # The layout variant for a races collection, from the event count and whether the first is
  # featured. Defaults to the full upcoming-races list; callers can pass an explicit count and
  # featured flag (e.g. the race-day "Upcoming Races" section, which excludes today's race).
  def event_collection_variant(count = upcoming_races.count, featured: is_featured?(upcoming_races.first))
    case count
    when 1 then "single"
    when 2 then featured ? "single" : "halves"
    when 3 then featured ? "halves" : "thirds"
    else "thirds"
    end
  end

  # The formatted date for an event's timestamp (e.g. "January 1, 2026"). Today's race is shown
  # in its own section whose heading already says it's today, so this is only ever rendered for
  # upcoming events and never needs a "Today" label.
  def event_timestamp(event)
    DateTime.parse(event.date).strftime("%B %-e, %Y")
  end

  # The icon + date span shown for an upcoming event. Not rendered for today's race (its section
  # heading already says it's today). Only confirmed, upcoming events reach here — the list
  # excludes cancelled ones — so the icon is always a calendar check.
  def event_timestamp_tag(event)
    content_tag :span, raw("#{icon_svg('classic', 'light', 'calendar-check')} #{event_timestamp(event)}")
  end

  # The "Live tracking" indicator for an event with a tracking link, or nil if there's none.
  # While the race is in progress it's highlighted and pulses; otherwise it's muted to signal
  # tracking exists but isn't live yet.
  def event_live_tracking_tag(event, event_weather = nil)
    return if event.blank? || event.tracking_url.blank?
    in_progress = is_in_progress?(event, event_weather)
    icon = in_progress ? icon_svg("classic", "regular", "signal-stream") : icon_svg("classic", "light", "signal-stream")
    options = {}
    options[:class] = "entry__highlight entry__highlight--live" if in_progress
    content_tag :span, options do
      raw("#{icon} #{content_tag(:a, 'Live tracking', href: event.tracking_url, rel: 'noopener', target: '_blank')}")
    end
  end
end
