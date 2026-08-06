# (Re)generates the Strava-ready description for an Intervals.icu activity.
#
# Deliberately source-agnostic — it knows nothing about Whoop. The Whoop workout path enqueues
# it today, but any other webhook could, losing only the 🔥 line. Kept separate from
# WhoopWebhookJob so writing descriptions and syncing Whoop metrics stay independent concerns
# and retry on their own. Concurrent duplicates are deduped by the generator's per-activity
# Redis lock, and a retry re-composes: the wording may differ, but the same information lands.
class ActivityDescriptionJob < ApplicationJob
  # @param activity_id [String, Integer] The Intervals.icu activity id.
  # @param whoop_strain [Float, nil] Whoop strain for the 🔥 line; omit when there's no Whoop
  #   context and the line is left out.
  def perform(activity_id, whoop_strain = nil)
    ActivityDescription::Generator.new.generate!(activity_id, whoop_strain: whoop_strain)
    Rails.logger.info("Activity description generated for activity #{activity_id}")
  end
end
