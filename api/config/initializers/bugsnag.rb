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
end
