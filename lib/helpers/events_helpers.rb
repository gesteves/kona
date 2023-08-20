module EventsHelpers
  def is_today?(date)
    event_date = Time.rfc3339(date)
    today = Time.current.in_time_zone(event_date.zone)
    event_date.to_date == today.to_date
  end

  def is_race_day?
    data.events.any? { |e| is_today?(e.date) && !e.canceled }
  end
end
