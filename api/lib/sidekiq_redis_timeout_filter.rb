# Bugsnag on_error callback that drops the Redis read timeouts Sidekiq raises from its own fetch
# loop — as opposed to from job code — because Sidekiq already handles them correctly and nothing
# is lost when they happen.
#
# Sidekiq's fetch loop is a BRPOP with a 2s server-side timeout, and redis-client adds the
# configured read timeout on top rather than racing it against it. config/initializers/sidekiq.rb
# has the arithmetic and explains why the server's timeout is 10 (a 12s window). When the worker
# VM is descheduled by its host for longer than that window, every processor thread blocked in
# BRPOP has its deadline expire the moment the VM resumes, so they all raise in the same
# millisecond. That is not a hypothetical: it was measured on fly.io as ~10s of cumulative CPU
# steal (`/proc/stat` field 8) on an otherwise 99.6%-idle shared-cpu-1x machine, against a Redis
# with an empty slowlog and no restart — i.e. the server answered fine and nobody was listening.
#
# Sidekiq's own response is already the correct one: Sidekiq::Processor#handle_fetch_exception
# reports once per processor, sleeps 1s, retries, and logs "Redis is online" on recovery. No job
# is lost, delayed, or duplicated — the queue simply wasn't polled for a few seconds. The only
# casualty is alert volume: `@down` is per-Processor and config/sidekiq.yml sets concurrency 5, so
# a single freeze produces five identical Bugsnag reports for an event nobody can act on.
#
# ⚠️ This is deliberately narrow. Three independent conditions must all hold, and every one of
# them is load-bearing — do not relax this into "ignore RedisClient errors":
#
#   1. We're in the Sidekiq server process. A Redis timeout raised in Puma still reports.
#   2. There's no Sidekiq job context. Bugsnag's server middleware stashes the job in
#      request_data[:sidekiq] for the duration of a job (Bugsnag::Middleware::Sidekiq), so a
#      timeout raised by job code still reports; only the fetch loop and Sidekiq's own pollers
#      run without it.
#   3. The error is a RedisClient::TimeoutError. A Redis that is genuinely unreachable raises
#      CannotConnectError, which is *not* a subclass of TimeoutError — verified against
#      redis-client 0.29.0, where CannotConnectError and TimeoutError are siblings both
#      descending from ConnectionError. That sibling relationship is what lets this filter stay
#      this simple while still paging on a real outage.
#
# If this ever raises, Bugsnag's OnErrorCallbacks rescues it and treats the callback as
# non-cancelling, so the failure mode is "report anyway" rather than "swallow silently".
class SidekiqRedisTimeoutFilter
  # @param report [Bugsnag::Report] The report about to be delivered.
  # @return [Boolean] false to drop the report, true to let it through.
  def self.call(report)
    return true unless Sidekiq.server?
    return true if report.request_data[:sidekiq]

    !report.original_error.is_a?(RedisClient::TimeoutError)
  end
end
