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

    # Every entry's nearest neighbors by embedding similarity, which the web build renders as
    # each article's static "You May Also Like" section.
    get "related" => "related#show"
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
      get    "connected-apps"       => "connected_apps#show",  as: :connected_apps
      delete "connected-apps/whoop" => "connected_apps#whoop", as: :whoop_connection

      # Bluesky attaches by form rather than by OAuth redirect, so it needs a page of its own;
      # all three of its actions live on that controller instead of on connected_apps#.
      get    "connected-apps/bluesky" => "bluesky#show",    as: :bluesky_connection
      post   "connected-apps/bluesky" => "bluesky#create",  as: nil
      delete "connected-apps/bluesky" => "bluesky#destroy", as: nil

      # The current location, on a map. The POST writes the same Redis key as the bearer-gated
      # POST /api/location, through Location.store; the lookup resolves an address or names a
      # coordinate pair **without** writing anything, which is what lets the page stage a change
      # before it's saved.
      get  "location"        => "location#show",   as: :location
      get  "location/lookup" => "location#lookup", as: :location_lookup
      post "location"        => "location#create"

      # The contact-form spam quarantine. Named for what it holds, and deliberately not `/contact`
      # — that's the public form's own path (POST /api/contact), and nothing here receives a
      # submission.
      get    "spam"              => "spam#index",    as: :spam
      post   "spam/:id/not-spam" => "spam#not_spam", as: :spam_not_spam
      delete "spam/:id"          => "spam#destroy",  as: :spam_message

      # GPX tracks rendered as static map images through Mapbox. `preview` and `download` proxy
      # the render rather than pointing the browser at Mapbox, because the Static Images API
      # carries the secret token in a query parameter.
      # ⚠️ `course-maps/status` must stay above `course-maps/:id`, or it's swallowed as a track id.
      get    "course-maps"              => "course_maps#index",    as: :course_maps
      post   "course-maps"              => "course_maps#create"
      get    "course-maps/status"       => "course_maps#status",   as: :course_maps_status
      get    "course-maps/:id"          => "course_maps#show",     as: :course_map
      patch  "course-maps/:id"          => "course_maps#update"
      delete "course-maps/:id"          => "course_maps#destroy"
      get    "course-maps/:id/preview"  => "course_maps#preview",  as: :course_map_preview
      get    "course-maps/:id/download" => "course_maps#download", as: :course_map_download
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
