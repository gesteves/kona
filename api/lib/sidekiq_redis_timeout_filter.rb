# Bugsnag callback that drops the Redis read timeouts Sidekiq raises from its own fetch loop.
# Sidekiq already handles those correctly — report once, sleep, retry — so no job is lost; the
# only casualty is alert volume, since the flag is per-Processor and concurrency is 5, so one
# blip of CPU steal on the worker VM produces five identical unactionable reports.
#
# ⚠️ Deliberately narrow. All three conditions are load-bearing — never relax this into
# "ignore RedisClient errors":
#   1. In the Sidekiq server process, so a timeout raised in Puma still reports.
#   2. No Sidekiq job context, so a timeout raised by job code still reports. Bugsnag's server
#      middleware stashes the job in request_data[:sidekiq] for a job's duration; only the fetch
#      loop and Sidekiq's own pollers run without it.
#   3. A TimeoutError specifically. An unreachable Redis raises CannotConnectError, which is a
#      sibling of TimeoutError rather than a subclass, so a real outage still pages.
#
# Bugsnag treats a raising callback as non-cancelling, so the failure mode is "report anyway".
class SidekiqRedisTimeoutFilter
  # @param report [Bugsnag::Report] The report about to be delivered.
  # @return [Boolean] false to drop the report, true to let it through.
  def self.call(report)
    return true unless Sidekiq.server?
    return true if report.request_data[:sidekiq]

    !report.original_error.is_a?(RedisClient::TimeoutError)
  end
end
