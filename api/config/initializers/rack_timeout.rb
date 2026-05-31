# rack-timeout caps total request wall-time so a single slow request can't hold a Puma thread
# on the lone fly machine (WEB_CONCURRENCY=1 × RAILS_MAX_THREADS=3 = 3 threads total). It's the
# whole-request backstop that complements the per-hop HTTParty timeouts (see http_timeouts.rb):
# those bound each upstream call, this bounds everything — sequential upstream calls, retry
# backoff, and any non-HTTP work — so no request can exceed the budget regardless of where it
# blocks. rack-timeout injects a `RequestTimeoutException` (a direct Exception subclass, so the
# services' broad `rescue StandardError` in with_retries/rescue_with can't swallow it). A killed
# request returns non-2xx, which the api-proxy refuses to durably cache, and the live-update
# controller recovers on the next visibilitychange.
#
# The middleware is auto-inserted by rack-timeout's Railtie (skipped in test). Its budget can't
# be set from Ruby in 0.7.0 — it reads RACK_TIMEOUT_SERVICE_TIMEOUT at middleware-build time
# (gem default: 15s). Production sets it to 20s in fly.toml, leaving headroom for a legitimately
# slow multi-call widget (e.g. weather hits WeatherKit + air quality + pollen sequentially)
# while still cutting off the pathological retry-storm path.

# rack-timeout logs `ready` and `completed` at INFO — two lines per request — which would bury
# lograge's one-line summary. Keep only actual timeouts (`expired` / `timed_out` log at ERROR)
# and send them to STDOUT alongside the rest of the app's logs.
Rack::Timeout::Logger.device = $stdout
Rack::Timeout::Logger.level  = ::Logger::ERROR
