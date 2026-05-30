module TimeHelper
  # Returns the timezone resolved by the controller (from the owner's location), falling
  # back to TIME_ZONE or America/Denver.
  # @return [String] An IANA timezone ID.
  def location_time_zone
    @time_zone.presence || ENV.fetch("TIME_ZONE", "America/Denver")
  end

  # Returns the current time in the current location's timezone.
  # @return [ActiveSupport::TimeWithZone] The current time.
  def current_time
    Time.current.in_time_zone(location_time_zone)
  end
end
