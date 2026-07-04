Rails.application.routes.draw do
  # Two structural constraints here are enforced by spec/routing/routes_guard_spec.rb:
  # the *unmatched catch-all must stay the last route, and every top-level prefix must be
  # listed in RACK_ATTACK_KNOWN_PREFIXES (config/initializers/rack_attack.rb).

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Widget fragments (HTML) embedded into the static site.
  scope "widgets", module: "widgets", as: "widgets" do
    get "activity-stats" => "activity_stats#show"

    # Current weather widget markup.
    get "weather/current" => "weather#current"

    # The home page's upcoming-races section (the featured event includes inline race-day weather).
    get "events/upcoming" => "events#upcoming"

    # The trending-articles widget, ranked from Plausible analytics at request time. The bare path
    # returns every trending article; /:id drops one Contentful id (an article page passes its own id
    # so it isn't listed as trending), keyed in the path so the edge cache (path-only) gives each its
    # own entry.
    get "articles/trending" => "articles#trending"
    get "articles/trending/:id" => "articles#trending_excluding", as: "articles_trending_excluding"

    # The "You May Also Like" widget: articles semantically related to :id (a Contentful entry id),
    # ranked at request time from precomputed Voyage embeddings.
    get "articles/related/:id" => "articles#related"

    # All-time Plausible pageview count for an article, keyed by Contentful ID.
    get "plausible/pageviews/:id" => "plausible#pageviews"

    # Returns the Whoop stats markup.
    get "whoop" => "whoop#show"
  end

  # Structured-data endpoints (accept or return data rather than widget markup).
  scope "api", module: "api", as: "api" do
    # Sets the current location (bearer-token-secured), replacing the old Netlify build hook.
    post "location" => "location#create"

    # standard.site verification data (DID + publication URI) the web build reads to emit
    # the .well-known endpoint and the <link rel="site.standard.*"> tags.
    get "standard-site" => "standard_site#show"
  end

  # Inbound webhooks, one controller per service.
  scope "webhooks", module: "webhooks", as: "webhooks" do
    # Contentful: re-syncs standard.site PDS records on entry publish/unpublish/delete
    # (HMAC request-verification gated).
    post "contentful" => "contentful#create"
  end

  # Whoop OAuth flow (owner-only authorize, public callback validated by state).
  get "/whoop/auth" => "whoop_oauth#authorize"
  get "/whoop/callback" => "whoop_oauth#callback"

  # Owner authentication (Google OAuth, restricted to OWNER_EMAIL). The OmniAuth request phase
  # (POST /auth/google_oauth2) is handled by the OmniAuth middleware before routing, so only the
  # callback/failure/login/logout need routes.
  get  "/login" => "sessions#new"
  post "/logout" => "sessions#destroy"
  get  "/auth/google_oauth2/callback" => "sessions#create"
  get  "/auth/failure" => "sessions#failure"

  # Sidekiq web UI for the standard.site sync queue. Gated by the owner session via a Rack guard
  # wired in config/initializers/sidekiq.rb (unauthenticated hits redirect to /login).
  mount Sidekiq::Web => "/sidekiq"

  # Redirect the project root to the main site. The host comes from SITE_URL (never
  # hardcoded); evaluated per-request so it tracks the configured value.
  root to: redirect(status: 301) { "#{ENV['SITE_URL'].to_s.chomp('/')}/" }

  # Catch-all for unmatched paths (mostly vulnerability scanners probing /api/.env and the
  # like). Handling them in a controller action instead of letting them raise
  # ActionController::RoutingError turns the multi-line exception+backtrace into a single
  # clean status=404 line via lograge, while still returning a plain-text 404. Must stay last
  # (spec-enforced).
  match "*unmatched", to: "application#route_not_found", via: :all
end
