require_relative "boot"

require "rails"
# Select the frameworks that you need:
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

# Require the gems in the Gemfile, and this includes each gem
# that you put in the :test, :development, or :production group.
Bundler.require(*Rails.groups)

module Api
  class Application < Rails::Application
    # Set the default configuration values of the Rails version that made this app.
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets tasks])

    # The test suite is in spec/, and not in test/.
    config.generators do |g|
      g.test_framework :rspec
    end

    # An error from the framework renders as plain text, and not as the default HTML page, because
    # this is an API for machines only. The lambda finds the constant at request time, when the
    # autoload of lib/ is active.
    config.exceptions_app = ->(env) { PlainTextExceptions.call(env) }

    # Blocks a bad request that goes directly to the origin, and limits its rate, before the
    # routing. The configuration is in config/initializers/rack_attack.rb, and it does nothing in
    # the test environment.
    config.middleware.use Rack::Attack
  end
end
