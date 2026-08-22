# rack-timeout limits the full time of a request. Thus one slow request cannot hold a Puma thread on
# the one fly machine, which has three threads. It is the limit for the full request, and the
# HTTParty timeouts in http_timeouts.rb are the limit for each upstream call. Those limit one call,
# and this one limits a group of calls in sequence, the waits between two attempts, and the work
# that is not HTTP. Its exception is a subclass of Exception, thus the `rescue StandardError` of a
# service cannot catch it.
#
# RACK_TIMEOUT_SERVICE_TIMEOUT gives the budget, and fly.toml sets it to 20s. rack-timeout 0.7.0
# reads it when it makes the middleware, and Ruby code cannot set it. That time is enough for a
# widget that makes many calls, and it still stops a large group of retries.

# rack-timeout writes two INFO lines for each request, and those would hide the summary of lograge.
# Keep the timeouts only, which it writes at the ERROR level.
Rack::Timeout::Logger.device = $stdout
Rack::Timeout::Logger.level  = ::Logger::ERROR
