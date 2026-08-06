require "httparty"

# Default connect and read timeouts for every upstream HTTP call. Every service reaches its API
# through the module-level HTTParty methods, which resolve through HTTParty::Basement, so
# setting the defaults here covers every call site in one place.
#
# Without this each call inherits Net::HTTP's ~60s defaults, and a couple of stalled upstreams
# would tie up all three Puma threads — worse still under with_retries, where a hang isn't a
# raised error until those 60s elapse. rack_timeout.rb backstops the request as a whole; this
# caps the individual hops. Per-call options still win.
HTTParty::Basement.open_timeout 5
HTTParty::Basement.read_timeout 10
