# Processes a verified Whoop webhook event: syncs the day's strain (and sleep performance /
# recovery) to Intervals.icu wellness, writes per-workout strain on the matched activity,
# and regenerates the activity's description. Enqueued by Webhooks::WhoopController after
# signature + user verification; all writes are idempotent PUTs of absolute values, so the
# inherited retry: 5 is safe (an improvement over domestique's fire-and-forget dispatch).
class WhoopWebhookJob < ApplicationJob
  # @param event_type [String] e.g. "workout.updated", "sleep.updated", "recovery.updated".
  # @param resource_id [String] The event's resource UUID (a sleep UUID for sleep/recovery events).
  # @param trace_id [String] Whoop's trace id, for log correlation.
  def perform(event_type, resource_id, trace_id)
    WhoopWebhookProcessor.new.process(event_type, resource_id)
    Rails.logger.info("Whoop webhook processed: #{event_type} (id=#{resource_id}, trace=#{trace_id})")
  end
end
