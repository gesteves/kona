require 'active_support/all'
module LocationHelpers
  # Returns the time zone ID for the location.
  # @param location [Hash] The location data hash containing time zone information.
  # @return [String] The time zone ID for the location.
  def location_time_zone(location = data.location)
    location&.time_zone&.time_zone_id || 'America/Denver'
  end

  # Returns the current time in the current location's time zone
  # @return [DateTime] The current time in the local time zone
  def current_time
    Time.current.in_time_zone(location_time_zone)
  end
end
