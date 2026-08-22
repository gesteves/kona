# The command 'rails generate rspec:install' copies this file into spec/.
require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
# Stop a delete of the database data if the environment is production.
abort("The Rails environment is running in production mode!") if Rails.env.production?
require 'rspec/rails'
# rspec-sidekiq, which the :test bundler group loads, puts Sidekiq in fake mode: perform_async
# adds the job to an array in memory, with no Redis, and a spec reads it with
# have_enqueued_sidekiq_job.
# Put each additional require below this line. Ruby loads Rails only at this point.

# The shared examples and the custom matchers. Do not give a file here a name that ends with
# _spec.rb, because RSpec would require it and also run it as a spec.
Rails.root.glob('spec/support/**/*.rb').sort_by(&:to_s).each { |f| require f }

# The /api/* widget endpoints need the API_TOKEN bearer token, which the web proxy adds in
# production. A request spec sets a constant token and gives `headers: auth_headers` on each
# request to an endpoint that needs it.
module ApiAuthHelper
  API_TEST_TOKEN = "test-api-token".freeze

  def auth_headers(extra = {})
    { "Authorization" => "Bearer #{API_TEST_TOKEN}" }.merge(extra)
  end
end

# A Google OAuth sign-in controls the pages for the owner only (/whoop/auth and /sidekiq). The
# OmniAuth test mode replaces the provider. Thus `sign_in_as` only makes the auth hash and calls
# the callback, and the owner session then stays set for each subsequent request in the example.
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

  # Completes a Google sign-in with the given email. The default is the test owner. It returns
  # after the app sets the owner session cookie.
  def sign_in_as(email: "owner@example.com", verified: true)
    mock_owner_auth(email: email, verified: verified)
    get "/auth/google_oauth2/callback"
  end
end

RSpec.configure do |config|
  # Remove this line to let the app use ActiveRecord.
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

  # If you let the app use ActiveRecord, make these lines active. If you do not
  # want each example in a transaction, set use_transactional_fixtures to
  # false.
  #
  # config.fixture_paths = [
  #   Rails.root.join('spec/fixtures')
  # ]
  # config.use_transactional_fixtures = true

  # RSpec Rails uses the metadata to add different behavior to your tests. For
  # example, it lets you call `get` and `post` in a request spec:
  #
  #     RSpec.describe UsersController, type: :request do
  #       # ...
  #     end
  #
  # The features documentation gives the available types, for example at
  # https://rspec.info/features/8-0/rspec-rails
  #
  # RSpec can also find this behavior from the location. For example,
  # /spec/models would give the same behavior as `type: :model`. But that
  # behavior is old and a future version will remove it.
  #
  # To use that behavior, make the line below active.
  # config.infer_spec_type_from_file_location!

  # Remove the lines of the Rails gems from a backtrace.
  config.filter_rails_from_backtrace!
  # You can also remove the lines of another gem:
  # config.filter_gems_from_backtrace("gem name")
end
