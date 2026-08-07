module EventsHelper
  # Whether the event is today, in the given timezone.
  # @param event [OpenStruct, nil]
  # @param time_zone [String] An IANA timezone id.
  def today?(event, time_zone)
    return false if event.blank?
    parse_event_date(event, time_zone) == Time.current.in_time_zone(time_zone).to_date
  end

  # Today's race, if any (an event that's today and confirmed).
  # @param events [Array<OpenStruct>, nil]
  # @param time_zone [String] An IANA timezone id.
  # @return [OpenStruct, nil]
  def todays_race(events, time_zone)
    return if events.blank?
    events.find { |e| today?(e, time_zone) && e.going }
  end

  # Whether today is a race day.
  # @param events [Array<OpenStruct>, nil]
  # @param time_zone [String] An IANA timezone id.
  def race_day?(events, time_zone)
    todays_race(events, time_zone).present?
  end

  # Whether a confirmed event is happening right now. Prefers the event's own race-day daylight
  # window, which covers both the right day and daytime at the event's location; falls back to
  # today-and-daytime in the given timezone when those sun times aren't available.
  # @param event [OpenStruct, nil] The event.
  # @param time_zone [String] An IANA timezone id.
  # @param event_weather [EventWeatherPresenter, nil] The featured race's weather.
  def in_progress?(event, time_zone, event_weather: nil)
    return false if event.blank? || !event.going
    window = event_daylight_window(event_weather)
    return window.cover?(Time.current) if window
    daytime?(nil, time_zone) && today?(event, time_zone)
  end

  # @return [Range, nil] The event day's sunrise..sunset window, or nil without sun times. The
  #   sun times are absolute instants, so callers need no timezone conversion.
  def event_daylight_window(event_weather)
    sunrise = event_weather&.sunrise
    sunset = event_weather&.sunset
    return if sunrise.blank? || sunset.blank?
    Time.parse(sunrise)..Time.parse(sunset)
  end

  # @return [OpenStruct, nil] The daytime forecast for the event's date.
  def event_forecast(event)
    event_forecast_day(event)&.daytime_forecast
  end

  # @return [OpenStruct, nil] The forecast day covering the event's date, which also carries
  #   its sunrise and sunset.
  def event_forecast_day(event)
    return nil if event.blank? || event.weather&.forecast_daily&.days.blank?
    event_date = parse_event_date(event)
    return nil if event_date.nil?

    event.weather.forecast_daily.days.find do |day|
      day_start = Date.parse(day.forecast_start)
      day_end = Date.parse(day.forecast_end)
      event_date >= day_start && event_date < day_end
    end
  end

  # The upcoming races to show: confirmed events today or later, soonest first. Four when the
  # next one is featured, three otherwise. Callers should keep the result — each call re-parses
  # and re-sorts every event.
  # @param events [Array<OpenStruct>, nil] Every event.
  # @param time_zone [String] An IANA timezone id.
  # @return [Array<OpenStruct>]
  def upcoming_races(events, time_zone)
    return [] if events.blank?

    today = Time.current.in_time_zone(time_zone).to_date
    # Parsed once per event rather than once per comparison, and an event with no usable date is
    # dropped instead of taking the whole widget down.
    upcoming = events
      .filter_map do |e|
        date = e.going ? parse_event_date(e, time_zone) : nil
        [date, e] if date && date >= today
      end
      .sort_by(&:first)
      .map(&:last)
    next_event = upcoming.first
    featured = next_event.present? && close?(next_event, time_zone)
    upcoming.take(featured ? 4 : 3)
  end

  # Whether the event is today or within the next 10 days.
  # @param event [OpenStruct, nil]
  # @param time_zone [String] An IANA timezone id.
  def close?(event, time_zone)
    return false if event.blank?
    event_date = parse_event_date(event, time_zone)
    return false if event_date.nil?

    # Both bounds are reckoned in the caller's timezone. Taking the upper one in the server's
    # instead makes a race exactly 10 days out featured or not depending on the machine's clock.
    today = Time.current.in_time_zone(time_zone).to_date
    event_date >= today && event_date <= today + 10
  end

  # Whether the event is the first of the upcoming races.
  # @param event [OpenStruct, nil]
  # @param upcoming [Array<OpenStruct>] The upcoming races (see #upcoming_races).
  def next?(event, upcoming)
    return false if event.blank?
    event.sys&.id == upcoming.first&.sys&.id
  end

  # Whether the event gets the featured treatment — an expanded card with race-day weather —
  # which the next race does when it's within 10 days.
  # @param event [OpenStruct, nil] The event.
  # @param upcoming [Array<OpenStruct>] The upcoming races.
  # @param time_zone [String] An IANA timezone id.
  def featured?(event, upcoming, time_zone)
    return false if event.blank?
    close?(event, time_zone) && next?(event, upcoming)
  end

  # @return [String] The layout variant for a races collection, from its size and whether the
  #   first event is featured.
  def event_collection_variant(count, featured:)
    case count
    when 1 then "single"
    when 2 then featured ? "single" : "halves"
    when 3 then featured ? "halves" : "thirds"
    else "thirds"
    end
  end

  # @return [String] The event's date, formatted. Only ever rendered for upcoming events, so it
  #   never needs a "Today" label — today's race has its own section.
  def event_timestamp(event)
    parse_event_date(event)&.strftime("%B %-e, %Y")
  end

  # @return [String] The icon and date span for an upcoming event. Only confirmed events reach
  #   here, so the icon is always a calendar check.
  def event_timestamp_tag(event)
    content_tag :span, raw("#{icon_svg('classic', 'light', 'calendar-check')} #{event_timestamp(event)}")
  end

  # The "Live tracking" indicator, highlighted while the race is in progress and muted
  # otherwise, to signal that tracking exists but isn't live yet.
  # @param event [OpenStruct, nil] The event.
  # @param time_zone [String] An IANA timezone id.
  # @param event_weather [EventWeatherPresenter, nil] The featured race's weather.
  # @return [String, nil] The markup, or nil when the event has no tracking link.
  def event_live_tracking_tag(event, time_zone, event_weather: nil)
    return if event.blank? || event.tracking_url.blank?
    in_progress = in_progress?(event, time_zone, event_weather: event_weather)
    icon = in_progress ? icon_svg("classic", "regular", "signal-stream") : icon_svg("classic", "light", "signal-stream")
    options = {}
    options[:class] = "entry__highlight entry__highlight--live" if in_progress
    content_tag :span, options do
      raw("#{icon} #{content_tag(:a, 'Live tracking', href: event.tracking_url, rel: 'noopener', target: '_blank')}")
    end
  end

  private

  # Parses an event's date, in `time_zone` when given.
  #
  # ⚠️ Contentful will happily hold an event with no date, and every caller here is on the races
  # widget's render path — a bare Time.parse takes the whole widget down over one bad entry
  # instead of dropping a single card.
  # @param event [OpenStruct, nil]
  # @param time_zone [String, nil] An IANA timezone id.
  # @return [Date, nil]
  def parse_event_date(event, time_zone = nil)
    date = event&.date
    return if date.blank?

    parsed = Time.parse(date)
    time_zone.present? ? parsed.in_time_zone(time_zone).to_date : parsed.to_date
  rescue ArgumentError, TypeError
    nil
  end
end
