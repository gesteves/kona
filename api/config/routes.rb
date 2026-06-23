Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Widget fragments embedded into the static site, under the /api namespace.
  get "/api/activity-stats" => "api/activity_stats#show"

  # Current weather widget markup.
  get "/api/weather/current" => "api/weather#current"

  # The home page's upcoming-races section (the featured event includes inline race-day weather).
  get "/api/events/upcoming" => "api/events#upcoming"

  # The trending-articles widget, ranked from Plausible analytics at request time. The bare path
  # returns every trending article; /exclude/:ids drops a caller-supplied, comma-separated set of
  # Contentful ids (the cards the embedding page already shows), keyed in the path so the edge cache
  # (path-only) gives each exclusion set its own entry.
  get "/api/articles/trending" => "api/articles#trending"
  get "/api/articles/trending/exclude/:ids" => "api/articles#trending_excluding"

  # All-time Plausible pageview count for an article, keyed by Contentful ID.
  get "/api/plausible/pageviews/:id" => "api/plausible#pageviews"

  # Returns the Whoop stats markup.
  get "/api/whoop" => "api/whoop#show"

  # Whoop OAuth flow (owner-only authorize, public callback validated by state).
  get "/whoop/auth" => "whoop_oauth#authorize"
  get "/whoop/callback" => "whoop_oauth#callback"

  # Sets the current location (bearer-token-secured), replacing the old Netlify build hook.
  post "/api/location" => "api/location#create"

  # Contentful webhook: re-syncs standard.site PDS records on entry publish/unpublish/delete
  # (HMAC request-verification gated).
  post "/api/webhooks/contentful" => "api/webhooks#contentful"

  # standard.site verification data (DID + publication URI) the web build reads to emit
  # the .well-known endpoint and the <link rel="site.standard.*"> tags.
  get "/api/standard-site" => "api/standard_site#show"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Redirect the project root to the main site. The host comes from SITE_URL (never
  # hardcoded); evaluated per-request so it tracks the configured value.
  root to: redirect(status: 301) { "#{ENV['SITE_URL'].to_s.chomp('/')}/" }

  # Catch-all for unmatched paths (mostly vulnerability scanners probing /api/.env and the
  # like). Handling them in a controller action instead of letting them raise
  # ActionController::RoutingError turns the multi-line exception+backtrace into a single
  # clean status=404 line via lograge, while still returning a plain-text 404. Must stay last.
  match "*unmatched", to: "application#route_not_found", via: :all
end
