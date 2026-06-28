# This file is copied to spec/ when you run 'rails generate rspec:install'
require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?
require 'rspec/rails'
# rspec-sidekiq (loaded via the :test bundler group) puts Sidekiq in fake mode: perform_async
# pushes to an in-memory array (no Redis) and specs assert with have_enqueued_sidekiq_job.
# Add additional requires below this line. Rails is not loaded until this point!

# Requires supporting ruby files with custom matchers and macros, etc, in
# spec/support/ and its subdirectories. Files matching `spec/**/*_spec.rb` are
# run as spec files by default. This means that files in spec/support that end
# in _spec.rb will both be required and run as specs, causing the specs to be
# run twice. It is recommended that you do not name files matching this glob to
# end with _spec.rb. You can configure this pattern with the --pattern
# option on the command line or in ~/.rspec, .rspec or `.rspec-local`.
#
# The following line is provided for convenience purposes. It has the downside
# of increasing the boot-up time by auto-requiring all files in the support
# directory. Alternatively, in the individual `*_spec.rb` files, manually
# require only the support files necessary.
#
# Rails.root.glob('spec/support/**/*.rb').sort_by(&:to_s).each { |f| require f }

# The /api/* widget endpoints require the API_TOKEN bearer (injected by the web proxy in
# production). Request specs set a deterministic token and pass `headers: auth_headers` on
# requests to gated endpoints.
module ApiAuthHelper
  API_TEST_TOKEN = "test-api-token".freeze

  def auth_headers(extra = {})
    { "Authorization" => "Bearer #{API_TEST_TOKEN}" }.merge(extra)
  end
end

# Owner-only surfaces (/whoop/auth, /sidekiq) are gated by a Google OAuth sign-in. OmniAuth test
# mode short-circuits the provider, so `sign_in_as` just mocks the auth hash and drives the
# callback, leaving the owner session set for subsequent requests in the same example.
OmniAuth.config.test_mode = true
OmniAuth.config.logger = Rails.logger

module OwnerAuthHelper
  def mock_owner_auth(email:, verified: true)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "test-uid",
      info: { email: email },
      extra: { raw_info: { email_verified: verified } }
    )
  end

  # Completes a Google sign-in as the given email (defaults to the test owner) and returns once
  # the owner session cookie is set.
  def sign_in_as(email: "owner@example.com", verified: true)
    mock_owner_auth(email: email, verified: verified)
    get "/auth/google_oauth2/callback"
  end
end

RSpec.configure do |config|
  # Remove this line to enable support for ActiveRecord
  config.use_active_record = false

  config.include ApiAuthHelper, type: :request
  config.include OwnerAuthHelper, type: :request

  config.before do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end

  config.before(type: :request) do
    @original_api_token = ENV["API_TOKEN"]
    ENV["API_TOKEN"] = ApiAuthHelper::API_TEST_TOKEN
  end

  config.after(type: :request) do
    ENV["API_TOKEN"] = @original_api_token
  end

  # If you enable ActiveRecord support you should uncomment these lines,
  # note if you'd prefer not to run each example within a transaction, you
  # should set use_transactional_fixtures to false.
  #
  # config.fixture_paths = [
  #   Rails.root.join('spec/fixtures')
  # ]
  # config.use_transactional_fixtures = true

  # RSpec Rails uses metadata to mix in different behaviours to your tests,
  # for example enabling you to call `get` and `post` in request specs. e.g.:
  #
  #     RSpec.describe UsersController, type: :request do
  #       # ...
  #     end
  #
  # The different available types are documented in the features, such as in
  # https://rspec.info/features/8-0/rspec-rails
  #
  # You can also infer these behaviours automatically by location, e.g.
  # /spec/models would pull in the same behaviour as `type: :model` but this
  # behaviour is considered legacy and will be removed in a future version.
  #
  # To enable this behaviour uncomment the line below.
  # config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!
  # arbitrary gems may also be filtered via:
  # config.filter_gems_from_backtrace("gem name")
end
