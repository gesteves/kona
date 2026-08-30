require "active_support/core_ext/integer/time"

Rails.application.configure do
  # A setting here replaces the same setting in config/application.rb.

  # Let a code change apply immediately, with no restart of the server.
  config.enable_reloading = true

  # Do not load all the code at the start.
  config.eager_load = false

  # Show a full error report.
  config.consider_all_requests_local = true

  # Let the server send its timing data.
  config.server_timing = true

  # Set the Action Controller cache on or off. By default it is off.
  # Run `rails dev:cache` to change it.
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true
    config.public_file_server.headers = { "cache-control" => "public, max-age=#{2.days.to_i}" }
  else
    config.action_controller.perform_caching = false
  end

  # Change this to :null_store for no cache.
  config.cache_store = :memory_store

  # Write each deprecation message to the Rails log.
  config.active_support.deprecation = :log

  # Mark the code that caused a redirect, in the log.
  config.action_dispatch.verbose_redirect_logs = true

  # Raise an error for a translation that is absent.
  config.i18n.raise_on_missing_translations = true

  # Do not add the file names to a rendered view. This app serves markup for a machine, and those
  # HTML comments would make the output different from the production output.
  config.action_view.annotate_rendered_view_with_filenames = false

  # Raise an error when the only or except option of a before_action names an action that does not
  # exist.
  config.action_controller.raise_on_missing_callback_actions = true
end
