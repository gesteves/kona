# Processes a verified Whoop webhook event: syncs the day's strain, sleep performance, and
# recovery to Intervals.icu wellness, writes per-workout strain on the matched activity, and
# regenerates its description. Every write is an idempotent PUT of an absolute value, so the
# inherited retries are safe.
class WhoopWebhookJob < ApplicationJob
  # @param event_type [String] e.g. "workout.updated", "sleep.updated", "recovery.updated".
  # @param resource_id [String] The event's resource UUID; a sleep UUID for sleep and recovery
  #   events.
  # @param trace_id [String] Whoop's trace id, for log correlation.
  def perform(event_type, resource_id, trace_id)
    WhoopWebhookProcessor.new.process(event_type, resource_id)
    Rails.logger.info("Whoop webhook processed: #{event_type} (id=#{resource_id}, trace=#{trace_id})")
  end
end
