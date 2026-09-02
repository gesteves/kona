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

# A Rack middleware, with a plain require: the autoload of lib/ is not active at this point, and
# `autoload_lib` below ignores this directory for that reason.
require_relative "../lib/middleware/request_body_limit"

module Api
  class Application < Rails::Application
    # Set the default configuration values of the Rails version that made this app.
    config.load_defaults 8.1

    config.autoload_lib(ignore: %w[assets middleware tasks])

    # The test suite is in spec/, and not in test/.
    config.generators do |g|
      g.test_framework :rspec
    end

    # An error from the framework renders as plain text, and not as the default HTML page, because
    # this is an API for machines only. The lambda finds the constant at request time, when the
    # autoload of lib/ is active.
    config.exceptions_app = ->(env) { PlainTextExceptions.call(env) }

    # Refuses a body that is too large before rack-attack and before the routing. Refer to
    # lib/middleware/request_body_limit.rb. The railtie of rack-attack adds its own middleware
    # after this one, from an initializer. That middleware blocks a bad request that goes directly
    # to the origin, and limits its rate. Its configuration is in
    # config/initializers/rack_attack.rb, and it does nothing in the test environment.
    config.middleware.use RequestBodyLimit
  end
end
