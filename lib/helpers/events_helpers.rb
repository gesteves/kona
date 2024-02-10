module EventsHelpers
  # Checks if a given event is today based on a specific time zone.
  # @param event [Event] The event to check.
  # @return [Boolean] Returns true if the given event is today; false otherwise.
  def is_today?(event)
    event_date = Time.parse(event.date).in_time_zone(data.time_zone.timeZoneId) # Correction: Use `date` parameter
    today = Time.current.in_time_zone(data.time_zone.timeZoneId)
    event_date.to_date == today.to_date
  end

  # Finds today's race event, if any, excluding any that are canceled.
  # @return [Event, nil] The race event for today if one exists and is not canceled, nil otherwise.
  def todays_race
    data.events.find { |e| is_today?(e) && !e.canceled }
  end

  # Returns a collection of upcoming race events.
  # @return [Array<Event>] An array of event objects that are upcoming and not canceled.
  def upcoming_races
    data.events.select { |e| Time.parse(e.date).in_time_zone(data.time_zone.timeZoneId).beginning_of_day >= Time.current.in_time_zone(data.time_zone.timeZoneId).beginning_of_day }.reject(&:canceled)
  end

  # Determines if today is a race day.
  # @return [Boolean] True if there is a race event today that is not canceled; false otherwise.
  def is_race_day?
    todays_race.present?
  end
end
