# Sends the current location of the athlete to Intervals.icu, to the profile and to the weather
# configuration, outside the request path. Api::LocationController adds it to the queue after it
# stores the coordinates in Redis. You can do the sync more than one time, because it does nothing
# when the values do not change. Thus the retry window from the parent class (retry_for: 24.hours) is
# safe.
class LocationSyncJob < ApplicationJob
  # @param latitude [Float]
  # @param longitude [Float]
  def perform(latitude, longitude)
    LocationSync.new.call(latitude, longitude)
    Rails.logger.info("Location synced to Intervals.icu (#{latitude}, #{longitude})")
  end
end
