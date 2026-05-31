# Collapse Rails' default multi-line request logs into a single structured line per
# request. This is a headless, machine-only API behind a CDN proxy, so the per-request
# summary (which widget, status, duration) is all that's useful in the fly.io logs.
Rails.application.configure do
  config.lograge.enabled = !Rails.env.test?

  # The request host isn't in the default process_action payload — pull it from the
  # controller so we can see which origin (proxy vs. direct) served the request.
  config.lograge.custom_payload do |controller|
    { host: controller.request.host }
  end

  # Surface the host plus any path-segment ID the widget routes key off of (e.g. the
  # Contentful id on event weather / pageviews); other params are noise for this API.
  config.lograge.custom_options = lambda do |event|
    { host: event.payload[:host], params: event.payload[:params].slice("id") }
  end
end
