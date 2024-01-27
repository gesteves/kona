module EventsHelpers
  # Determines if a given date string represents the current day in a specific time zone.
  # @param date [String] The date in RFC 3339 format to be compared with the current day.
  # @return [Boolean] True if the given date is the current day, otherwise false.
  def is_today?(date)
    event_date = Time.rfc3339(date).in_time_zone(data.time_zone.timeZoneId)
    today = Time.current.in_time_zone(data.time_zone.timeZoneId)
    event_date.to_date == today.to_date
  end

  # Checks if any of the races scheduled is today and not canceled.
  # @return [Boolean] True if today is a race day, otherwise false.
  def is_race_day?
    data.events.any? { |e| is_today?(e.date) && !e.canceled }
  end
end
