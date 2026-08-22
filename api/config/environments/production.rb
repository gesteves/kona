require "active_support/core_ext/integer/time"

Rails.application.configure do
  # A setting here replaces the same setting in config/application.rb.

  # Rails does not load the code again between two requests.
  config.enable_reloading = false

  # Load all the code at the start, for more speed and less memory. A Rake task ignores this.
  config.eager_load = true

  # The app does not show a full error report.
  config.consider_all_requests_local = false

  # Let the view templates cache their fragments.
  config.action_controller.perform_caching = true

  # Keep each asset in the cache for a long time, because each name contains a digest.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Let an asset server give the images, the stylesheets, and the JavaScript.
  # config.asset_host = "http://assets.example.com"

  # Each request to the app comes through a reverse proxy that ends the SSL connection.
  config.assume_ssl = true

  # Make each request to the app use SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Do not redirect the default health check endpoint from http to https.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Write the log to STDOUT, with the id of the current request as a default tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change this to "debug" to write each line to the log. That can include data that identifies a
  # person.
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Keep the health checks out of the log.
  config.silence_healthcheck_path = "/up"

  # Do not write a deprecation message to the log.
  config.active_support.report_deprecations = false

  # Replace the default memory cache in this process with a store that keeps its data.
  # config.cache_store = :mem_cache_store

  # Let I18n use another language: a lookup in each language uses I18n.default_locale when it finds
  # no translation.
  config.i18n.fallbacks = true

  # Refuse a request with a false `Host` header or with an IP address in it. Those are DNS
  # rebinding attacks and Host-header attacks, and they are most of the scanner traffic that goes
  # directly to the origin. ALLOWED_HOSTS gives the list of permitted hosts, with a comma between
  # them. Never write a hostname in the code. There is a check here, thus the app accepts each host
  # until the variable has a value: the deploy is safe, and you then set the fly secret to make this
  # operate. The /up health check is not in this rule, thus the checks of fly, which use the
  # internal host, continue to pass.
  if ENV["ALLOWED_HOSTS"].present?
    config.hosts.concat(ENV["ALLOWED_HOSTS"].split(",").map(&:strip).reject(&:empty?))
    config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
  end
end
