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

  # Whether the event is happening right now (today, daytime, confirmed).
  def is_in_progress?(event)
    return false if event.blank?
    is_daytime? && is_today?(event) && event.going
  end

  # Whether the event is in progress and has a live tracking link.
  def is_trackable?(event)
    return false if event.blank?
    is_in_progress?(event) && event.tracking_url.present?
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
  # otherwise three. Mirrors the static site's build-time helper, reading @events.
  def upcoming_races
    return [] if @events.blank?
    upcoming = @events
      .select { |e| e.going && Time.parse(e.date).in_time_zone(location_time_zone).beginning_of_day >= current_time.beginning_of_day }
      .sort_by { |e| Time.parse(e.date) }
    next_event = upcoming.first
    featured = next_event.present? && is_close?(next_event)
    upcoming.take(featured ? 4 : 3)
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

  # The layout variant for the upcoming-races collection, from the event count and whether the
  # first is featured.
  def event_collection_variant
    case upcoming_races.count
    when 1 then "single"
    when 2 then is_featured?(upcoming_races.first) ? "single" : "halves"
    when 3 then is_featured?(upcoming_races.first) ? "halves" : "thirds"
    else "thirds"
    end
  end

  # "Today" if the event is today, otherwise the formatted date (e.g. "January 1, 2026").
  def event_timestamp(event)
    is_today?(event) ? "Today" : DateTime.parse(event.date).strftime("%B %-e, %Y")
  end

  # The calendar icon reflecting the event's status (cancelled / in progress / today / upcoming).
  def event_icon_svg(event)
    return icon_svg("classic", "light", "calendar-xmark") unless event.going
    return icon_svg("classic", "regular", "calendar-star") if is_in_progress?(event)
    return icon_svg("classic", "light", "calendar-star") if is_today?(event) && event.going
    return icon_svg("classic", "light", "calendar-check") if event.going
    icon_svg("classic", "light", "calendar")
  end

  # The icon + timestamp span for an event (highlighted while the race is in progress).
  def event_timestamp_tag(event)
    options = {}
    options[:class] = "entry__highlight" if is_in_progress?(event)
    content_tag :span, raw("#{event_icon_svg(event)} #{event_timestamp(event)}"), options
  end
end
