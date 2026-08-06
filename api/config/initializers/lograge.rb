# Collapses Rails' multi-line request logs into one structured line. This is a machine-only API
# behind a CDN proxy, so the summary — which widget, status, duration — is all that's useful.
Rails.application.configure do
  config.lograge.enabled = !Rails.env.test?

  # The host isn't in the default payload, and it's what shows whether a request came through
  # the proxy or hit the origin directly.
  config.lograge.custom_payload do |controller|
    { host: controller.request.host }
  end

  # The host plus any path-segment id the widget routes key off; other params are noise here.
  config.lograge.custom_options = lambda do |event|
    { host: event.payload[:host], params: event.payload[:params].slice("id") }
  end
end
