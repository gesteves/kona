# Allow any origin to fetch the public widget markup. These are public,
# credential-less GETs that get embedded into the static site (and others, if anyone cares),
# so a wildcard origin is fine. The OAuth and location endpoints are direct (non-browser)
# requests and deliberately not listed here.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "*"
    resource "/activity-stats", headers: :any, methods: [:get, :options], credentials: false
    resource "/whoop", headers: :any, methods: [:get, :options], credentials: false
    resource "/weather", headers: :any, methods: [:get, :options], credentials: false
  end
end
