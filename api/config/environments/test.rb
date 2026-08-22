# The test environment runs the test suite of your application only. You
# need it for nothing else. Note that your test database is a work area for
# the test suite: the code removes its data and makes the database again
# between two test runs. Do not depend on the data there.

Rails.application.configure do
  # A setting here replaces the same setting in config/application.rb.

  # During a test run, Rails does not watch the files, thus a reload is not necessary.
  config.enable_reloading = false

  # Eager loading loads your full application. For one test on your own machine, that
  # is usually not necessary and it makes your test suite slower. But use it in a
  # continuous integration system, to make sure that eager loading works before you
  # deploy your code.
  config.eager_load = ENV["CI"].present?

  # Configure the public file server for the tests, with a cache-control header for more speed.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show a full error report.
  config.consider_all_requests_local = true
  config.cache_store = :null_store

  # Render an exception template for an exception that the app can catch, and raise for each other
  # exception.
  config.action_dispatch.show_exceptions = :rescuable

  # Do not use the request forgery protection in the test environment.
  config.action_controller.allow_forgery_protection = false

  # Write each deprecation message to stderr.
  config.active_support.deprecation = :stderr

  # Raise an error for a translation that is absent.
  # config.i18n.raise_on_missing_translations = true

  # Add the file names to a rendered view.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise an error when the only or except option of a before_action names an action that does not
  # exist.
  config.action_controller.raise_on_missing_callback_actions = true
end
