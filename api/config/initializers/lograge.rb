# Makes one structured line from the many request log lines of Rails. This is an API for machines
# only, behind a CDN proxy. Thus the summary — the widget, the status, and the time — is all that a
# person needs.
Rails.application.configure do
  config.lograge.enabled = !Rails.env.test?

  # The host is not in the default data, and it is what shows if a request came through the proxy or
  # went to the origin directly.
  config.lograge.custom_payload do |controller|
    { host: controller.request.host }
  end

  # The host, and the id in a path segment that a widget route uses. Each other parameter gives no
  # information here.
  config.lograge.custom_options = lambda do |event|
    { host: event.payload[:host], params: event.payload[:params].slice("id") }
  end
end
