module TimeHelper
  # Returns the timezone resolved by the controller (from the owner's location), falling
  # back to TIME_ZONE or America/Denver. The optional location arg is ignored (the ported
  # weather helpers pass one); the controller-resolved @time_zone is already location-derived.
  # @return [String] An IANA timezone ID.
  def location_time_zone(_location = nil)
    @time_zone.presence || ENV.fetch("TIME_ZONE", "America/Denver")
  end

  # Returns the current time in the current location's timezone.
  # @return [ActiveSupport::TimeWithZone] The current time.
  def current_time
    Time.current.in_time_zone(location_time_zone)
  end

  # Formats a timestamp in the given timezone as "HH:MM <abbr>AM</abbr>", wrapping the
  # meridiem in an <abbr> tag. Returns an HTML-unsafe string (render with `raw`).
  # @param time [String, Time, nil] The time to format.
  # @param time_zone [String, nil] The IANA timezone id.
  # @return [String, nil]
  def time_with_meridiem_abbr(time, time_zone)
    return if time.blank? || time_zone.blank?

    Time.parse(time.to_s)
        .in_time_zone(time_zone)
        .strftime("%I:%M %p")
        .gsub(/(am|pm)/i, "<abbr>\\1</abbr>")
  end
end
