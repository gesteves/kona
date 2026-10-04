# Makes the description and the name of an activity from its Intervals.icu data, and writes them
# to the Strava copy of the activity.
#
# Two webhooks add it to the queue: the Strava webhook, through StravaActivityJob, when an activity
# arrives, and the Whoop webhook when Whoop scores the workout. The generator gets the Whoop strain
# itself, thus the two runs give the same description, and the one that comes last has the most
# data. The Redis lock of the generator, which is for one activity, puts a second run of the same
# moment back in the queue. A second attempt makes the description again: the words can be
# different, but the data is the same.
class ActivityDescriptionJob < ApplicationJob
  # The wait before a run that found the lock of another run tries again.
  BUSY_DELAY = 1.minute

  # @param activity_id [String, Integer] The Intervals.icu activity id.
  def perform(activity_id)
    # The jid is the token of the lock, thus a retry of this job can enter the lock that its own
    # attempt left.
    if ActivityDescription::Generator.new.generate!(activity_id, lock_token: jid) == :busy
      self.class.perform_in(BUSY_DELAY, activity_id)
      return
    end

    Rails.logger.info("Activity description generated for activity #{activity_id}")
  end
end
