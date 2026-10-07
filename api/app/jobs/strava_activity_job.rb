# Finds the Intervals.icu activity of a new Strava activity, then adds its description job.
#
# Strava sends the webhook before Intervals.icu has the activity, or before Intervals.icu knows its
# Strava id. Thus a miss raises, and the job tries again with the usual waits of Sidekiq, which
# start at approximately 15 seconds, for the 24 hours of ApplicationJob. When those 24 hours end, the
# activity gets the Rouvy rename of StravaNameJob and no description.
class StravaActivityJob < ApplicationJob
  # The Intervals.icu activity is not there yet. ⚠️ Bugsnag discards it, because a miss is the normal
  # wait. Refer to config/initializers/bugsnag.rb.
  class ActivityNotSynced < StandardError; end

  sidekiq_retries_exhausted do |msg, exception|
    strava_id = msg["args"].first
    Rails.logger.warn("Strava activity #{strava_id}: no description, Rouvy rename only (#{exception.message})")
    StravaNameJob.perform_async(strava_id)
  end

  # @param strava_id [String] The Strava activity id.
  # @param event_time [Integer] The Unix time of the event.
  def perform(strava_id, event_time)
    day = Time.at(event_time.to_i).in_time_zone(Location.new.time_zone).to_date
    activity = Intervals.new.activities!(oldest: day - 2, newest: day + 1)
                        .find { |candidate| candidate[:strava_id].to_s == strava_id.to_s }
    raise ActivityNotSynced, "Intervals.icu has no activity with Strava id #{strava_id} yet" if activity.nil?

    ActivityDescriptionJob.perform_async(activity[:id])
  end
end
