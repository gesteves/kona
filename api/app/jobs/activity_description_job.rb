# Makes the description of an Intervals.icu activity for Strava, and it can make it again.
#
# It knows nothing about Whoop, on purpose. The Whoop workout path adds it to the queue today, but
# each other webhook could do the same, and only the 🔥 line would go away. It is separate from
# WhoopWebhookJob, thus the description work and the Whoop metric sync stay separate and each one
# runs again by itself. The Redis lock of the generator, which is for one activity, removes a second
# job at the same time. A second attempt makes the description again: the words can be different,
# but the data is the same.
class ActivityDescriptionJob < ApplicationJob
  # @param activity_id [String, Integer] The Intervals.icu activity id.
  # @param whoop_strain [Float, nil] The Whoop strain for the 🔥 line. Omit it when there is no Whoop
  #   data, and the description then has no such line.
  def perform(activity_id, whoop_strain = nil)
    ActivityDescription::Generator.new.generate!(activity_id, whoop_strain: whoop_strain)
    Rails.logger.info("Activity description generated for activity #{activity_id}")
  end
end
