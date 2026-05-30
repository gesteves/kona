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
end
