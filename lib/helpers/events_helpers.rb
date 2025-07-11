module EventsHelpers
  # Checks if a given event is today based on a specific time zone.
  # @param event [Event] The event to check.
  # @return [Boolean] Returns true if the given event is today; false otherwise.
  def is_today?(event)
    event_date = Time.parse(event.date).in_time_zone(location_time_zone)
    event_date.to_date == current_time.to_date
  end

  # Finds today's race event, if any.
  # @return [Event, nil] The race event for today if one exists, nil otherwise.
  def todays_race
    data.events.find { |e| is_today?(e) && e.going }
  end

  # Returns a collection of upcoming race events.
  # Returns four events if the next one is in the next 10 days, otherwise returns three events.
  # @return [Array<Event>] An array of event objects that are today or in the future.
  def upcoming_races
    upcoming = data.events.sort_by { |e| Time.parse(e.date) }.select { |e| Time.parse(e.date).in_time_zone(location_time_zone).beginning_of_day >= current_time.beginning_of_day && e.going }
    upcoming.take(is_close?(upcoming.first) ? 4 : 3)
  end

  # Determines if today is a race day.
  # @return [Boolean] True if there is a race event today; false otherwise.
  def is_race_day?
    todays_race.present?
  end

  # Determines if the event is happening in the next 10 days.
  # @param event [Event] The event to check.
  # @return [Boolean] True if the event is happening in the next 10 days; false otherwise.
  def is_close?(event)
    event_date = Time.parse(event.date).in_time_zone(location_time_zone)
    event_date.to_date >= current_time.to_date && event_date.to_date <= 10.days.from_now.to_date
  end

  # Determines if the event is the next one.
  # @param event [Event] The event to check.
  # @return [Boolean] True if the event is the next one; false otherwise.
  def is_next?(event)
    event == upcoming_races.first
  end

  # Determines if the event has a weather forecast for the event date.
  # @param event [Event] The event to check.
  # @return [Boolean] True if the event has weather data; false otherwise.
  def has_weather_data?(event)
    event.weather.present?
  end

  # Determines if the event should be featured.
  # @param event [Event] The event to check.
  # @return [Boolean] True if the event is featured; false otherwise.
  def is_featured?(event)
    is_close?(event) && is_next?(event) && has_weather_data?(event)
  end

  # Determines if the event is currently in progress.
  # @param event [Object] The event object to check.
  # @return [Boolean] True if the event occurs today, is during daytime, and is confirmed.
  def is_in_progress?(event)
    is_daytime? && is_today?(event) && event.going
  end

  # Determines if the event is happening and there's a live tracking link.
  # @param event [Object] The event object to check.
  # @return [Boolean] True if the event is in progress and has a tracking URL, otherwise false.
  def is_trackable?(event)
    is_in_progress?(event) && event.tracking_url.present?
  end

  # Retrieves the appropriate event icon SVG based on the event status.
  # @param event [Object] The event object to evaluate.
  # @return [String] The HTML-safe SVG icon representing the event's current status.
  def event_icon_svg(event)
    return icon_svg("classic", "light",   "calendar-xmark") if !event.going
    return icon_svg("classic", "light",   "calendar-star")  if is_trackable?(event)
    return icon_svg("classic", "regular", "calendar-star")  if is_in_progress?(event)
    return icon_svg("classic", "light",   "calendar-star")  if is_today?(event) && event.going
    return icon_svg("classic", "light",   "calendar-check") if event.going
    icon_svg("classic", "light", "calendar")
  end

  # Formats the event timestamp.
  # @param event [Object] The event object containing the date.
  # @return [String] "Today" if the event is today, otherwise a formatted date string (e.g., "January 1, 2024").
  def event_timestamp(event)
    if is_today?(event)
      "Today"
    else
      DateTime.parse(event.date).strftime('%B %-e, %Y')
    end
  end

  # Generates an HTML span tag with the event's tracking link.
  # @param event [Object] The event object to render.
  # @return [String] An HTML-safe string with the event's tracking link.
  def event_tracking_tag(event)
    return "" unless is_trackable?(event)
    content_tag :span, class: "entry__highlight entry__highlight--live" do
      "#{icon_svg("classic", "solid", "circle-small")} #{content_tag(:a, "Live results", href: event.tracking_url, rel: "noopener", target: "_blank")}"
    end
  end

  # Generates an HTML span tag with the event's icon and timestamp.
  # @param event [Object] The event object to render.
  # @return [String] An HTML-safe string with the event's icon and formatted timestamp.
  def event_timestamp_tag(event)
    options = {}
    options[:class] = "entry__highlight" if is_in_progress?(event) && !is_trackable?(event)
    content_tag :span, options do
      "#{event_icon_svg(event)} #{event_timestamp(event)}"
    end
  end
end
