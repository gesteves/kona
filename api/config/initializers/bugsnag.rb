# Sends each exception that nothing catches to Bugsnag. The railtie of the gem adds its Rack
# middleware and reads the exception code of ActionDispatch. Thus Bugsnag gets each exception,
# although this API renders an error as plain text (refer to lib/plain_text_exceptions.rb).
#
# Only production sends a report: notify_release_stages has "production" only, and
# BUGSNAG_API_KEY has no value in development and in test. Thus this does nothing on your machine
# and in CI.
Bugsnag.configure do |config|
  config.api_key = ENV["BUGSNAG_API_KEY"]
  config.release_stage = Rails.env
  config.notify_release_stages = %w[production]

  # Removes the reports from the Sidekiq fetch loop when the host stops the worker VM for a short
  # time. Sidekiq recovers from that by itself. Refer to the filter for the three conditions that
  # keep it from a true failure. It is in a lambda, thus the autoloaded constant resolves at the
  # first report and not at the start.
  config.add_on_error(->(report) { SidekiqRedisTimeoutFilter.call(report) })

  # Removes the BadRequest that a spam bot causes when it posts a contact-form body that is not
  # correct UTF-8. Nobody can act on that report. Refer to the filter for the reason that it applies
  # to that one endpoint.
  config.add_on_error(->(report) { ContactBadRequestFilter.call(report) })
end
