require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
# require "active_job/railtie"
# require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Api
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets tasks])

    # The suite lives in spec/, not test/.
    config.generators do |g|
      g.test_framework :rspec
    end

    # Framework-level errors render as plain text rather than the default HTML pages, since
    # this is a machine-only API. The lambda defers resolving the constant until request time,
    # when lib/ autoloading is active.
    config.exceptions_app = ->(env) { PlainTextExceptions.call(env) }

    # Blocks and throttles abusive direct-to-origin requests before routing. Configured in
    # config/initializers/rack_attack.rb, and a no-op in the test env.
    config.middleware.use Rack::Attack
  end
end
