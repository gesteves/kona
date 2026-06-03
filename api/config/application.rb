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

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Use RSpec for generated specs (the suite lives in spec/, not test/).
    config.generators do |g|
      g.test_framework :rspec
    end

    # Render framework-level 4xx/5xx errors as plain text instead of the default HTML pages
    # (this is a headless, machine-only API). The lambda defers resolving the constant until
    # request time, when lib/ autoloading is active.
    config.exceptions_app = ->(env) { PlainTextExceptions.call(env) }

    # Block/throttle abusive direct-to-origin requests before they reach routing.
    # Configured in config/initializers/rack_attack.rb (no-op in the test env).
    config.middleware.use Rack::Attack
  end
end
