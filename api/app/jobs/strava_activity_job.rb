# Finds the Intervals.icu activity of a new Strava activity, then adds its description job.
#
# ⚠️ Strava sends the webhook before Interv.icu has the activity, or before Intervals.icu knows its
# Strava id. Thus a miss is not a failure: the job tries again after 1, 2, 3, 4, and 5 minutes, then
# stops with a log line. It does not use the 24-hour window of ApplicationJob: an activity that never
# reaches Intervals.icu, for example one that a person makes by hand in Strava, must not retry all day.
class StravaActivityJob < ApplicationJob
  # The Intervals.icu activity is not there yet.
  class ActivityNotSynced < StandardError; end

  RETRY_DELAYS = [ 1, 2, 3, 4, 5 ].map(&:minutes).freeze

  # ⚠️ `dead: false`: a miss after the last attempt is a normal result, and the Dead set is for a
  # true failure.
  sidekiq_options retry: RETRY_DELAYS.size, retry_for: nil, dead: false

  # Each other error gets the usual wait of Sidekiq, with the same number of attempts.
  sidekiq_retry_in do |count, exception|
    RETRY_DELAYS[count] if exception.is_a?(ActivityNotSynced)
  end

  sidekiq_retries_exhausted do |msg, exception|
    Rails.logger.warn("Strava activity #{msg['args'].first}: no description (#{exception.message})")
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
