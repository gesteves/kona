require "httparty"

# Default connect/read timeouts for every upstream HTTP call.
#
# All services reach their third-party APIs through the module-level `HTTParty.get/.post`
# — either via `ApplicationService#get_json`/`#post_json` or directly (WeatherKit, Whoop,
# TrainerRoad, Font Awesome) — and both routes resolve through `HTTParty::Basement`. Setting
# the defaults on Basement therefore covers every call site, present and future, in one place.
#
# Without this, each call inherits Net::HTTP's ~60s open/read defaults. On the single fly
# machine (WEB_CONCURRENCY=1 × RAILS_MAX_THREADS=3 = 3 Puma threads) a couple of stalled
# upstreams would tie up every thread — and `ApplicationService#with_retries` makes it worse,
# since a hang isn't a raised error until that 60s elapses, after which it sleeps and retries.
# Bounding each hop lets the retry/backoff logic fail fast instead of hanging. rack-timeout
# (see rack_timeout.rb) backstops the request as a whole; this caps the individual hops.
#
# Per-call options still win — pass `open_timeout:` / `read_timeout:` / `timeout:` to override.
HTTParty::Basement.open_timeout 5
HTTParty::Basement.read_timeout 10
