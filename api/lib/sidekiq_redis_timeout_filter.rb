# A Bugsnag callback that removes the Redis read timeouts that Sidekiq raises from its own fetch
# loop. Sidekiq already acts on those correctly: it reports one time, waits, and tries again. Thus no
# job goes away. The only problem is the number of alerts: the flag belongs to each Processor and the
# concurrency is 5, thus one short period of CPU competition on the worker VM makes five identical
# reports that nobody can act on.
#
# ⚠️ This is narrow, on purpose. All three conditions are necessary. Never change this into "ignore
# each RedisClient error":
#   1. The code is in the Sidekiq server process, thus a timeout from Puma still gives a report.
#   2. There is no Sidekiq job, thus a timeout from the code of a job still gives a report. The
#      server middleware of Bugsnag puts the job in request_data[:sidekiq] for the length of that
#      job. Only the fetch loop and the pollers of Sidekiq run with no job.
#   3. The error is a TimeoutError. A Redis that the code cannot reach raises CannotConnectError,
#      which is beside TimeoutError and not below it. Thus a true failure still gives an alert.
#
# A callback that raises does not stop a Bugsnag report, thus a failure here gives a report.
class SidekiqRedisTimeoutFilter
  # @param report [Bugsnag::Report] The report that Bugsnag is ready to send.
  # @return [Boolean] False to remove the report, and true to send it.
  def self.call(report)
    return true unless Sidekiq.server?
    return true if report.request_data[:sidekiq]

    !report.original_error.is_a?(RedisClient::TimeoutError)
  end
end
