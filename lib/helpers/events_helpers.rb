module EventsHelpers
  # Checks if a given date is today based on a specific time zone.
  # @param date [String] The date to check, expected in a string format parseable by `Time.parse`.
  # @return [Boolean] Returns true if the given date is today; false otherwise.
  def is_today?(date)
    event_date = Time.parse(date).in_time_zone(data.time_zone.timeZoneId) # Correction: Use `date` parameter
    today = Time.current.in_time_zone(data.time_zone.timeZoneId)
    event_date.to_date == today.to_date
  end

  # Finds today's race event, if any, excluding any that are canceled.
  # @return [Event, nil] The race event for today if one exists and is not canceled, nil otherwise.
  def todays_race
    data.events.find { |e| is_today?(e.date) && !e.canceled }
  end

  # Determines if today is a race day.
  # @return [Boolean] True if there is a race event today that is not canceled; false otherwise.
  def is_race_day?
    todays_race.present?
  end
end
