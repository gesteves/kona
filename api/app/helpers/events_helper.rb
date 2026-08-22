module EventsHelper
  # Tells if the event is today, in the given timezone.
  # @param event [OpenStruct, nil]
  # @param time_zone [String] An IANA timezone id.
  def today?(event, time_zone)
    return false if event.blank?
    parse_event_date(event, time_zone) == Time.current.in_time_zone(time_zone).to_date
  end

  # The race of today, if there is one: an event that is today and is confirmed.
  # @param events [Array<OpenStruct>, nil]
  # @param time_zone [String] An IANA timezone id.
  # @return [OpenStruct, nil]
  def todays_race(events, time_zone)
    return if events.blank?
    events.find { |e| today?(e, time_zone) && e.going }
  end

  # Tells if today is a race day.
  # @param events [Array<OpenStruct>, nil]
  # @param time_zone [String] An IANA timezone id.
  def race_day?(events, time_zone)
    todays_race(events, time_zone).present?
  end

  # Tells if a confirmed event occurs now. It uses the daylight window of the race day of the
  # event, which gives the correct day and the daytime at the location of the event. If those sun
  # times are not available, it uses today and the daytime in the given timezone.
  # @param event [OpenStruct, nil] The event.
  # @param time_zone [String] An IANA timezone id.
  # @param event_weather [EventWeatherPresenter, nil] The featured race's weather.
  def in_progress?(event, time_zone, event_weather: nil)
    return false if event.blank? || !event.going
    window = event_daylight_window(event_weather)
    return window.cover?(Time.current) if window
    daytime?(nil, time_zone) && today?(event, time_zone)
  end

  # @return [Range, nil] The sunrise..sunset window of the event day, or nil if there are no sun
  #   times. The sun times are absolute instants, thus a caller needs no timezone change.
  def event_daylight_window(event_weather)
    sunrise = event_weather&.sunrise
    sunset = event_weather&.sunset
    return if sunrise.blank? || sunset.blank?
    Time.parse(sunrise)..Time.parse(sunset)
  end

  # @return [OpenStruct, nil] The daytime forecast for the date of the event.
  def event_forecast(event)
    event_forecast_day(event)&.daytime_forecast
  end

  # @return [OpenStruct, nil] The forecast day for the date of the event, which also has its
  #   sunrise and its sunset.
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

  # The upcoming races to show: the confirmed events of today or later, the first one soonest.
  # There are four races when the next race is a featured race, and three in all other conditions.
  # A caller must keep the result, because each call parses and sorts each event again.
  # @param events [Array<OpenStruct>, nil] All the events.
  # @param time_zone [String] An IANA timezone id.
  # @return [Array<OpenStruct>]
  def upcoming_races(events, time_zone)
    return [] if events.blank?

    today = Time.current.in_time_zone(time_zone).to_date
    # The code parses one time for each event, and not one time for each comparison. It removes an
    # event with an incorrect date, and does not stop the full widget.
    upcoming = events
      .filter_map do |e|
        date = e.going ? parse_event_date(e, time_zone) : nil
        [ date, e ] if date && date >= today
      end
      .sort_by(&:first)
      .map(&:last)
    next_event = upcoming.first
    featured = next_event.present? && close?(next_event, time_zone)
    upcoming.take(featured ? 4 : 3)
  end

  # Tells if the event is today or in the next 10 days.
  # @param event [OpenStruct, nil]
  # @param time_zone [String] An IANA timezone id.
  def close?(event, time_zone)
    return false if event.blank?
    event_date = parse_event_date(event, time_zone)
    return false if event_date.nil?

    # Both limits use the timezone of the caller. With the upper limit in the timezone of the
    # server, the clock of the machine would decide if a race exactly 10 days ahead is a featured
    # race.
    today = Time.current.in_time_zone(time_zone).to_date
    event_date >= today && event_date <= today + 10
  end

  # Tells if the event is the first of the upcoming races.
  # @param event [OpenStruct, nil]
  # @param upcoming [Array<OpenStruct>] The upcoming races (see #upcoming_races).
  def next?(event, upcoming)
    return false if event.blank?
    event.sys&.id == upcoming.first&.sys&.id
  end

  # Tells if the event is a featured event, that is, a large card with the weather of the race
  # day. The next race is a featured event when it is in the next 10 days.
  # @param event [OpenStruct, nil] The event.
  # @param upcoming [Array<OpenStruct>] The upcoming races.
  # @param time_zone [String] An IANA timezone id.
  def featured?(event, upcoming, time_zone)
    return false if event.blank?
    close?(event, time_zone) && next?(event, upcoming)
  end

  # @return [String] The layout for a collection of races. It comes from the size of the
  #   collection and from the state of the first event.
  def event_collection_variant(count, featured:)
    case count
    when 1 then "single"
    when 2 then featured ? "single" : "halves"
    when 3 then featured ? "halves" : "thirds"
    else "thirds"
    end
  end

  # @return [String] The date of the event, in a readable format. It renders only for an upcoming
  #   event, thus it needs no "Today" label. The race of today has its own section.
  def event_timestamp(event)
    parse_event_date(event)&.strftime("%B %-e, %Y")
  end

  # @return [String] The icon and the date span for an upcoming event. Only a confirmed event
  #   comes here, thus the icon is always a calendar check.
  def event_timestamp_tag(event)
    date = parse_event_date(event)
    # This uses <time datetime>, as ArticlesHelper#article_permalink_timestamp does. Without it, a
    # machine cannot read the date.
    timestamp = date ? content_tag(:time, event_timestamp(event), datetime: date.iso8601) : nil
    content_tag :span, raw("#{icon_svg('classic', 'light', 'calendar-check')} #{timestamp}")
  end

  # The "Live tracking" indicator. It is bright while the race occurs, and dark in all other
  # conditions, to show that tracking exists but is not live.
  # @param event [OpenStruct, nil] The event.
  # @param time_zone [String] An IANA timezone id.
  # @param event_weather [EventWeatherPresenter, nil] The featured race's weather.
  # @return [String, nil] The markup, or nil if the event has no tracking link.
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

  # Parses the date of an event, in `time_zone` if the caller gives one.
  #
  # ⚠️ Contentful can hold an event with no date, and each caller here is on the render path of
  # the races widget. A plain Time.parse would stop the full widget because of one bad entry, and
  # not remove one card.
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
