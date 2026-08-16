Rails.application.routes.draw do
  # Two structural constraints here are enforced by spec/routing/routes_guard_spec.rb:
  # the *unmatched catch-all must stay the last route, and every top-level prefix must be
  # listed in RACK_ATTACK_KNOWN_PREFIXES (config/initializers/rack_attack.rb).

  # Health check: 200 when the app boots cleanly, 500 otherwise.
  get "up" => "rails/health#show", as: :rails_health_check

  # Widget fragments (HTML) embedded into the static site.
  scope "widgets", module: "widgets", as: "widgets" do
    get "activity-stats" => "activity_stats#show"

    get "weather/current" => "weather#current"

    # The featured event includes inline race-day weather.
    get "events/upcoming" => "events#upcoming"

    # Ranked from Plausible analytics at request time. The bare path returns every trending
    # article; /:id drops one Contentful id, so an article page can exclude itself. The id is a
    # path segment because the edge cache is keyed on path only.
    get "articles/trending" => "articles#trending"
    get "articles/trending/:id" => "articles#trending_excluding", as: "articles_trending_excluding"

    # Articles semantically related to :id, ranked from precomputed Voyage embeddings.
    get "articles/related/:id" => "articles#related"

    get "plausible/pageviews/:id" => "plausible#pageviews"
    get "whoop" => "whoop#show"
  end

  # Structured-data endpoints (accept or return data rather than widget markup).
  scope "api", module: "api", as: "api" do
    # Sets the current location and syncs it to Intervals.icu.
    post "location" => "location#create"

    # The public site's contact form, reached through the web proxy. Browser-reachable, unlike
    # the rest of /api/*.
    post "contact" => "contact#create"

    # The standard.site DID and publication URI the web build reads. Public.
    get "standard-site" => "standard_site#show"

    # Rebuilds and redeploys the static web site. Rate-limited by a Redis lock in the
    # controller, not by rack-attack.
    post "build" => "build#create"

    # Resolves the web build's posted Font Awesome allowlist to pre-rendered SVGs.
    post "icons" => "icons#create"
  end

  # Inbound webhooks, one controller per service.
  scope "webhooks", module: "webhooks", as: "webhooks" do
    # Keeps the PDS records, embeddings, image mirror, and static site in sync. HMAC-gated.
    post "contentful" => "contentful#create"

    # Syncs strain, sleep, and recovery to Intervals.icu. HMAC-gated.
    post "whoop" => "whoop#create"
  end

  # Everything below is owner-facing, and is drawn only off the public API hostname. `API_HOST`
  # names that hostname; where it's set these paths fall through to the 404 catch-all there, so
  # the public host serves nothing but `/up` and the three machine namespaces above. Unset (dev,
  # CI, the .fly.dev origin) draws them on every host.
  #
  # ⚠️ The zone's bot-protection skip rule is scoped to "every host except the admin one", which
  # is only safe because of this constraint — a route drawn outside this block is reachable on
  # the public host with managed rules and Super Bot Fight Mode skipped. Enforced by
  # spec/requests/host_constraints_spec.rb.
  admin_only = lambda do |request|
    api_host = ENV["API_HOST"].presence
    api_host.nil? || !request.host.casecmp?(api_host)
  end

  constraints(admin_only) do
    # Whoop OAuth flow (owner-only authorize, public callback validated by state).
    # ⚠️ WHOOP_REDIRECT_URI and the Whoop dashboard must name the admin host, not the API host.
    get "/whoop/auth" => "whoop_oauth#authorize"
    get "/whoop/callback" => "whoop_oauth#callback"

    # Owner authentication: Google OAuth restricted to OWNER_EMAIL. The OmniAuth request phase is
    # handled by middleware before routing, so only these four need routes — and for the same
    # reason it stays reachable on the API host, where the callback below no longer is, so a
    # sign-in can't complete there.
    get  "/signin" => "sessions#new"
    post "/signout" => "sessions#destroy"
    get  "/auth/google_oauth2/callback" => "sessions#create"
    get  "/auth/failure" => "sessions#failure"

    # Gated by the owner session, via the Rack guard in config/initializers/sidekiq.rb.
    mount Sidekiq::Web => "/sidekiq"

    # The owner-facing admin UI, gated by the owner session in Admin::BaseController. Drawn at the
    # ROOT, not under /admin: these routes exist only on the admin host, where the prefix would
    # just repeat the hostname. `scope module:` keeps the controllers grouped under Admin:: without
    # putting that in the path.
    #
    # ⚠️ Admin pages therefore claim top-level paths on this host. Check a new one against the
    # zone's scanner-noise custom rule before adding it — that rule blocks whole prefix families
    # (`/config/`, `/home/`, `/analytics/`, `/deploy/`, …) zone-wide, and would 403 a page named
    # after one. See the root CLAUDE.md.
    scope module: "admin" do
      root to: "home#show"
      get    "connected-accounts"       => "connected_accounts#show",  as: :connected_accounts
      delete "connected-accounts/whoop" => "connected_accounts#whoop", as: :whoop_connection

      # The contact-form spam quarantine. Distinct from the public POST /api/contact, which is a
      # different path on a different host.
      get    "contact"              => "contact#index",    as: :contact
      post   "contact/:id/not-spam" => "contact#not_spam", as: :contact_not_spam
      delete "contact/:id"          => "contact#destroy",  as: :contact_message

      # GPX tracks rendered as static map images through Mapbox. `preview` and `download` proxy
      # the render rather than pointing the browser at Mapbox, because the Static Images API
      # carries the secret token in a query parameter.
      # ⚠️ `maps/status` must stay above `maps/:id`, or it's swallowed as a track id.
      get    "maps"              => "maps#index",    as: :maps
      post   "maps"              => "maps#create"
      get    "maps/status"       => "maps#status",   as: :maps_status
      get    "maps/:id"          => "maps#show",     as: :map
      patch  "maps/:id"          => "maps#update"
      delete "maps/:id"          => "maps#destroy"
      get    "maps/:id/preview"  => "maps#preview",  as: :map_preview
      get    "maps/:id/download" => "maps#download", as: :map_download
    end
  end

  # The public API host has no UI, so point a browser that lands on it at the real site. Drawn
  # after the block above, so on the admin host the home page claims "/" first and this is only
  # ever reached on the public host. Evaluated per-request, so it tracks SITE_URL rather than
  # baking in a host.
  get "/" => redirect(status: 301) { "#{ENV['SITE_URL'].to_s.chomp('/')}/" }

  # Catch-all, mostly for vulnerability scanners. Handling them in a controller rather than
  # raising a RoutingError turns a multi-line backtrace into one clean lograge 404 line.
  # ⚠️ Must stay last; enforced by spec/routing/routes_guard_spec.rb.
  match "*unmatched", to: "application#route_not_found", via: :all
end
