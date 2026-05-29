# Allow any origin to fetch the public /activity-stats markup. It's a public,
# credential-less GET that gets embedded into the static site (and others, if anyone cares),
# so a wildcard origin is fine.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "*"
    resource "/activity-stats", headers: :any, methods: [:get, :options], credentials: false
  end
end
