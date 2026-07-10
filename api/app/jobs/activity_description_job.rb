# (Re)generates the Strava-ready description for an Intervals.icu activity.
#
# Deliberately source-agnostic: it knows nothing about Whoop. The Whoop workout path enqueues
# it (passing the matched workout's strain for the 🔥 line), but if the Whoop integration ever
# goes away, another webhook can enqueue it with no strain and the description simply composes
# without that line. Kept separate from WhoopWebhookJob so "write activity descriptions" and
# "sync Whoop metrics to Intervals.icu" are independent concerns — and so the description
# retries on its own (a failed Anthropic call or Intervals.icu write propagates and is retried
# by Sidekiq rather than swallowed). Concurrent duplicates are deduped by the generator's
# per-activity Redis lock; a retry re-composes the description (idempotent in outcome — the
# LLM wording may differ, but the same information lands).
class ActivityDescriptionJob < ApplicationJob
  # @param activity_id [String, Integer] The Intervals.icu activity id.
  # @param whoop_strain [Float, nil] Optional Whoop strain for the 🔥 line. Omit (or nil) when
  #   there's no Whoop context — the description is then composed without it.
  def perform(activity_id, whoop_strain = nil)
    ActivityDescription::Generator.new.generate!(activity_id, whoop_strain: whoop_strain)
    Rails.logger.info("Activity description generated for activity #{activity_id}")
  end
end
