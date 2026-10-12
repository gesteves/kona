# Sends the current location of the athlete to Intervals.icu, to the profile and to the weather
# configuration, outside the request path. Api::LocationController adds it to the queue after it
# stores the coordinates in Redis. You can do the sync more than one time, because it does nothing
# when the values do not change. Thus the retry window from the parent class (retry_for: 24.hours) is
# safe.
class LocationSyncJob < ApplicationJob
  # @param latitude [Float]
  # @param longitude [Float]
  def perform(latitude, longitude)
    # ⚠️ Send the stored location only. Two saves close together, or a retry that runs late, would
    # otherwise put an older location on Intervals.icu after the newer one.
    unless Location.stored == [ latitude.to_f, longitude.to_f ]
      Rails.logger.info("Location sync skipped: (#{latitude}, #{longitude}) is no longer the stored location")
      return
    end

    LocationSync.new.call(latitude, longitude)
    Rails.logger.info("Location synced to Intervals.icu (#{latitude}, #{longitude})")
  end
end
