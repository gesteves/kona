# Syncs the athlete's current location to Intervals.icu (profile + weather config) off the
# request path. Enqueued by Api::LocationController after it stores the coordinates in Redis.
# The sync is idempotent (skip-if-unchanged), so the inherited retry: 5 is safe.
class LocationSyncJob < ApplicationJob
  # @param latitude [Float]
  # @param longitude [Float]
  def perform(latitude, longitude)
    LocationSync.new.call(latitude, longitude)
    Rails.logger.info("Location synced to Intervals.icu (#{latitude}, #{longitude})")
  end
end
