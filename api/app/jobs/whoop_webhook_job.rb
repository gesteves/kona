# Acts on a Whoop webhook event that the app checked: it sends the strain, the sleep performance,
# and the recovery of the day to the Intervals.icu wellness record, it writes the strain of the
# workout on the activity that matches, and it makes the description of that activity again. Each
# write is a PUT of an absolute value that you can do more than one time, thus the retries from the
# parent class are safe.
class WhoopWebhookJob < ApplicationJob
  # @param event_type [String] For example "workout.updated", "sleep.updated", or
  #   "recovery.updated".
  # @param resource_id [String] The resource UUID of the event. It is a sleep UUID for a sleep event
  #   and for a recovery event.
  # @param trace_id [String] The trace id of Whoop, to find the related lines in the log.
  def perform(event_type, resource_id, trace_id)
    WhoopWebhookProcessor.new.process(event_type, resource_id)
    Rails.logger.info("Whoop webhook processed: #{event_type} (id=#{resource_id}, trace=#{trace_id})")
  end
end
