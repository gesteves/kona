Rails.application.routes.draw do
  # spec/routing/routes_guard_spec.rb enforces two rules here: the *unmatched catch-all must stay
  # the last route, and RACK_ATTACK_KNOWN_PREFIXES (config/initializers/rack_attack.rb) must
  # contain each top-level prefix.

  # The health check: 200 if the app starts correctly, and 500 if it does not.
  get "up" => "rails/health#show", as: :rails_health_check

  # The widget fragments (HTML) that go into the static site.
  scope "widgets", module: "widgets", as: "widgets" do
    get "activity-stats" => "activity_stats#show"

    get "weather/current" => "weather#current"

    # The featured event contains the weather for the day of the race.
    get "events/upcoming" => "events#upcoming"

    # The Plausible analytics give the order at request time. The home page and a Page call this.
    # An entry page does not: it already has its own recirculation sections.
    get "articles/trending" => "articles#trending"

    get "plausible/pageviews/:id" => "plausible#pageviews"
    get "whoop" => "whoop#show"
  end

  # The structured-data endpoints. They take or give data, and not widget markup.
  scope "api", module: "api", as: "api" do
    # Sets the current location and sends it to Intervals.icu.
    post "location" => "location#create"

    # The contact form of the public site, through the web proxy. A browser can reach it, and it
    # cannot reach the other /api/* paths.
    post "contact" => "contact#create"

    # The standard.site DID and publication URI that the web build reads. This is public.
    get "standard-site" => "standard_site#show"

    # Builds and deploys the static web site again. A Redis lock in the controller limits the
    # rate, and rack-attack does not.
    post "build" => "build#create"

    # Changes the Font Awesome list that the web build posts into rendered SVGs.
    post "icons" => "icons#create"

    # The nearest neighbors of each entry, by the similarity of the embeddings. The web build
    # renders them as the static "You May Also Like" section of each article.
    get "related" => "related#show"
  end

  # The inbound webhooks, with one controller for each service.
  scope "webhooks", module: "webhooks", as: "webhooks" do
    # Syncs the PDS records, the embeddings, the image mirror, and the static site. It needs an
    # HMAC.
    post "contentful" => "contentful#create"

    # Syncs the strain, the sleep, and the recovery to Intervals.icu. It needs an HMAC.
    post "whoop" => "whoop#create"
  end

  # Each route below is for the owner, and Rails draws it only off the public API hostname.
  # `API_HOST` names that hostname. Where it has a value, these paths go to the 404 catch-all
  # there, thus the public host serves only `/up` and the three machine namespaces above. With no
  # value (dev, CI, and the .fly.dev origin), Rails draws them on each host.
  #
  # ⚠️ The bot-protection skip rule of the zone applies to "each host but the admin one". This
  # constraint is what makes that rule safe: a route outside this block is available on the public
  # host, with the managed rules and Super Bot Fight Mode off.
  # spec/requests/host_constraints_spec.rb enforces this.
  admin_only = lambda do |request|
    api_host = ENV["API_HOST"].presence
    api_host.nil? || !request.host.casecmp?(api_host)
  end

  constraints(admin_only) do
    # The Whoop OAuth flow. Only the owner can authorize, and the state value checks the public
    # callback.
    # ⚠️ WHOOP_REDIRECT_URI and the Whoop dashboard must name the admin host, not the API host.
    get "/whoop/auth" => "whoop_oauth#authorize"
    get "/whoop/callback" => "whoop_oauth#callback"

    # The owner authentication: Google OAuth for OWNER_EMAIL only. Middleware does the OmniAuth
    # request phase before the routing, thus only these four paths need routes. For the same
    # reason that phase stays available on the API host. The callback below is not available
    # there, thus a sign-in cannot complete there.
    get  "/signin" => "sessions#new"
    post "/signout" => "sessions#destroy"
    get  "/auth/google_oauth2/callback" => "sessions#create"
    get  "/auth/failure" => "sessions#failure"

    # The owner session controls this, through the Rack guard in
    # config/initializers/sidekiq.rb.
    mount Sidekiq::Web => "/sidekiq"

    # The admin UI for the owner. The owner session in Admin::BaseController controls it. Rails
    # draws it at the ROOT, and not below /admin: these routes exist only on the admin host, where
    # the prefix would repeat the hostname. `scope module:` keeps the controllers together below
    # Admin:: and does not put that name in the path.
    #
    # ⚠️ Thus the admin pages use top-level paths on this host. Check a new page against the
    # scanner-noise custom rule of the zone before you add it. That rule blocks full prefix
    # families (`/config/`, `/home/`, `/analytics/`, `/deploy/`, and more) in the full zone, and
    # it would 403 a page with one of those names. Refer to the root CLAUDE.md.
    scope module: "admin" do
      root to: "home#show"
      get    "connected-apps"       => "connected_apps#show",  as: :connected_apps
      delete "connected-apps/whoop" => "connected_apps#whoop", as: :whoop_connection

      # Bluesky connects with a form, and not with an OAuth redirect. Thus it needs its own page,
      # and all three of its actions are on that controller, and not on connected_apps#.
      get    "connected-apps/bluesky" => "bluesky#show",    as: :bluesky_connection
      post   "connected-apps/bluesky" => "bluesky#create",  as: nil
      delete "connected-apps/bluesky" => "bluesky#destroy", as: nil

      # Mastodon does an OAuth round trip, and the owner must name an instance first: this app
      # registers itself on that instance and has no client before that. Thus the form, the
      # callback, and the disconnect are all on that controller.
      # ⚠️ The callback stays below /connected-apps, and it is not a top-level /mastodon path. Thus
      # it needs no new prefix in RACK_ATTACK_KNOWN_PREFIXES and no new name in the scanner-noise
      # rule of the zone.
      get    "connected-apps/mastodon"          => "mastodon#show",     as: :mastodon_connection
      post   "connected-apps/mastodon"          => "mastodon#create",   as: nil
      delete "connected-apps/mastodon"          => "mastodon#destroy",  as: nil
      get    "connected-apps/mastodon/callback" => "mastodon#callback", as: :mastodon_callback

      # Threads does an OAuth round trip with app credentials from the environment, thus it needs
      # no form: the Connect button of the card goes to the authorize action. The callback stays
      # below /connected-apps for the same reason as the Mastodon one.
      get    "connected-apps/threads/authorize" => "threads#authorize", as: :threads_authorize
      get    "connected-apps/threads/callback"  => "threads#callback",  as: :threads_callback
      delete "connected-apps/threads"           => "threads#destroy",   as: :threads_connection

      # The current location, on a map. The POST writes the same Redis key as the
      # POST /api/location that needs a bearer token, through Location.store. The lookup finds an
      # address or names a pair of coordinates and writes **nothing**, which is what lets the page
      # hold a change before the save.
      get  "location"        => "location#show",   as: :location
      get  "location/lookup" => "location#lookup", as: :location_lookup
      post "location"        => "location#create"

      # Builds and deploys the static site again, now or at a time that the owner picks. It adds
      # the same SiteBuildJob that a Contentful publish and POST /api/build add, with its own event
      # type. There is no page here: the nav opens a dialog, and the dialog posts to this path.
      post "republish" => "republish#create", as: :republish

      # The Social media page, which drafts one post for the connected social accounts. The nav
      # always holds it, and the page renders with no account connected: each row is then disabled.
      # The POST adds one job for each network that the owner ticked.
      get  "social" => "social#show", as: :social
      post "social" => "social#create"

      # The preview of the link that the owner pasted. ⚠️ `social/preview/image` must stay above
      # `social/preview`, or Rails reads it as part of that path.
      # The image is a proxy, and not a link to the other host: the CSP of the admin has
      # `img-src :self`. Refer to **The Social media page** in CLAUDE.md.
      get "social/preview/image" => "social#preview_image", as: :social_preview_image
      get "social/preview"       => "social#preview",       as: :social_preview

      # The spam quarantine of the contact form. The name says what it holds. It is not `/contact`,
      # on purpose, because that is the path of the public form (POST /api/contact), and nothing
      # here takes a submission.
      get    "spam"              => "spam#index",    as: :spam
      post   "spam/:id/not-spam" => "spam#not_spam", as: :spam_not_spam
      delete "spam/:id"          => "spam#destroy",  as: :spam_message

      # The GPX tracks, which Mapbox renders as static map images. `preview` and `download` proxy
      # the render and do not send the browser to Mapbox, because the Static Images API has the
      # secret token in a query parameter.
      # ⚠️ `course-maps/status` must stay above `course-maps/:id`. If it does not, Rails reads it
      # as a track id.
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

  # The public API host has no UI, thus this sends a browser that comes to it to the true site.
  # Rails draws it after the block above. Thus on the admin host the home page takes "/" first,
  # and only the public host uses this route. Rails evaluates it for each request, thus it follows
  # SITE_URL and does not contain a host.
  get "/" => redirect(status: 301) { "#{ENV['SITE_URL'].to_s.chomp('/')}/" }

  # The catch-all, mostly for vulnerability scanners. A controller answers them, and the code does
  # not raise a RoutingError. Thus one lograge 404 line replaces a backtrace of many lines.
  # ⚠️ This must stay last. spec/routing/routes_guard_spec.rb enforces this.
  match "*unmatched", to: "application#route_not_found", via: :all
end
