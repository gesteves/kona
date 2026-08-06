# rack-timeout caps total request wall-time, so one slow request can't hold a Puma thread on the
# lone fly machine (3 threads total). It's the whole-request backstop complementing the per-hop
# HTTParty timeouts in http_timeouts.rb: those bound each upstream call, this bounds sequential
# calls, retry backoff, and non-HTTP work alike. Its exception is a direct Exception subclass, so
# the services' `rescue StandardError` can't swallow it.
#
# The budget is set via RACK_TIMEOUT_SERVICE_TIMEOUT (20s in fly.toml), which rack-timeout 0.7.0
# reads at middleware-build time and can't be set from Ruby. That leaves headroom for a
# legitimately slow multi-call widget while still cutting off a retry storm.

# rack-timeout logs two INFO lines per request, which would bury lograge's summary. Keep only
# actual timeouts, which log at ERROR.
Rack::Timeout::Logger.device = $stdout
Rack::Timeout::Logger.level  = ::Logger::ERROR
