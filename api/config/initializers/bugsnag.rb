# Reports unhandled exceptions to Bugsnag. The gem's railtie auto-inserts its Rack
# middleware and hooks ActionDispatch's exception handling, so exceptions are captured
# even though this API renders errors as plain text (lib/plain_text_exceptions.rb).
#
# Only production actually notifies: notify_release_stages is limited to "production",
# and BUGSNAG_API_KEY is unset in development/test, so this is a no-op locally and in CI.
Bugsnag.configure do |config|
  config.api_key = ENV["BUGSNAG_API_KEY"]
  config.release_stage = Rails.env
  config.notify_release_stages = %w[production]

  # Drops the reports Sidekiq's fetch loop produces when the worker VM is briefly frozen by its
  # host, which Sidekiq already recovers from on its own. See the filter for the three
  # conditions that keep it from swallowing a real outage. Wrapped in a lambda so the autoloaded
  # constant resolves on first notify rather than during boot.
  config.add_on_error(->(report) { SidekiqRedisTimeoutFilter.call(report) })

  # Drops the unactionable BadRequest a spam bot produces by posting a contact form body that
  # isn't valid UTF-8. See the filter for why it's scoped to that one endpoint.
  config.add_on_error(->(report) { ContactBadRequestFilter.call(report) })
end
