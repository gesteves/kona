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
    data.events.find { |e| is_today?(e) && is_confirmed?(e) }
  end

  # Returns a collection of upcoming race events.
  # @return [Array<Event>] An array of event objects that are today or in the future.
  def upcoming_races
    data.events.sort_by { |e| Time.parse(e.date) }.select { |e| Time.parse(e.date).in_time_zone(location_time_zone).beginning_of_day >= current_time.beginning_of_day }.take(3)
  end

  # Determines if today is a race day.
  # @return [Boolean] True if there is a race event today; false otherwise.
  def is_race_day?
    todays_race.present?
  end

  # Determines if I'm registered for the event.
  # @param event [Object] The event object to check.
  # @return [Boolean] True if the event's status includes "Registered", otherwise false.
  def is_confirmed?(event)
    event.status.include?("Registered")
  end

  # Determines if I'm not starting this event.
  # @param event [Object] The event object to check.
  # @return [Boolean] True if the event's status includes "DNS" (Did Not Start), otherwise false.
  def is_dns?(event)
    event.status.include?("DNS")
  end

  # Determines if the event has been canceled.
  # @param event [Object] The event object to check.
  # @return [Boolean] True if the event's status includes "Canceled"), otherwise false.
  def is_canceled?(event)
    event.status.include?("Canceled")
  end

  # Determines if the event status is tentative, i.e. I'm considering it but haven't registered yet.
  # @param event [Object] The event object to check.
  # @return [Boolean] True if the event status is empty or includes "Tentative", otherwise false.
  def is_tentative?(event)
    event.status.empty? || event.status.include?("Tentative")
  end

  # Determines if the event is currently in progress.
  # @param event [Object] The event object to check.
  # @return [Boolean] True if the event occurs today, is during daytime, and is confirmed.
  def is_in_progress?(event)
    is_daytime? && is_today?(event) && is_confirmed?(event)
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
    return icon_svg("classic", "light",   "calendar-xmark") if is_canceled?(event) || is_dns?(event)
    return icon_svg("classic", "light",   "calendar-star")  if is_trackable?(event)
    return icon_svg("classic", "regular", "calendar-star")  if is_in_progress?(event)
    return icon_svg("classic", "light",   "calendar-check") if is_confirmed?(event)
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
    options[:title] = event.status.join(", ").presence || "Tentative"
    content_tag :span, options do
      "#{event_icon_svg(event)} #{event_timestamp(event)}"
    end
  end
end
