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
    data.events.find { |e| is_today?(e) }
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
end
