# api/ — Kona widget API

The Rails 8.1 API (Ruby 4.0.6). It serves small **HTML fragments** ("widgets") for the static `web/`
site, and it also has the structured-data endpoints and the inbound webhooks. It deploys to
**fly.io** as `kona-api`, with an `app` process and a `worker` process, and **Cloudflare** is in
front of the origin. Redis holds the cache, and there is **no database**.

This is a small Rails: it loads ActiveModel, ActionController, and ActionView only. It does not load
ActiveRecord, ActiveJob, ActionMailer, or ActionCable. Refer to the root
[`CLAUDE.md`](../CLAUDE.md) for the markup contract between web and api before you change a view,
and for the rules for a comment that this app obeys.

⚠️ **Write each comment, all the inline documentation, and each change to a `CLAUDE.md` file in
ASD-STE100 Simplified Technical English, and keep it short.** The root
[`CLAUDE.md`](../CLAUDE.md) has the full rule.

It also serves a small **admin UI** for the owner. That UI uses Web Awesome and it is at the root of
the admin host. It is the one part of the app with an asset pipeline and with a layout. Refer to
**The admin UI** below.

The routes are in three namespaces. `/widgets/*` gives HTML fragments, and a browser reaches them
through the proxy of the web app. `/api/*` gives structured data, and a caller reaches it directly
at the origin. `/webhooks/*` takes an inbound request, and the sending service reaches it directly.

The origin answers on **two host names**, and `config/routes.rb` keeps them apart. `API_HOST` names
the public host, and Rails draws each route for the owner off the *other* host, which is the admin
host. Thus the public host serves only `/up` and those three namespaces. ⚠️ **Put each new route for
the owner in that `constraints` block.** The bot-protection skip rule of the zone applies to "each
host but the admin one". Thus a route outside that block is available on the public host, with the
managed rules and Super Bot Fight Mode off.
`spec/requests/host_constraints_spec.rb` tests both directions.

## Endpoints

Each `/widgets/*` response is an HTML fragment (`layout false`). The edge TTL is the time that the
edge serves a cached copy before it gets a new one.

| Method | Path | Returns | Edge TTL |
|---|---|---|---|
| GET | `/up` | health check | — |
| GET | `/widgets/activity-stats` | Intervals.icu totals | 5 min |
| GET | `/widgets/weather/current` | weather/AQI/pollen | 5 min |
| GET | `/widgets/events/upcoming` | upcoming races; the featured event has inline race-day weather | 1 hr |
| GET | `/widgets/articles/trending` | "hot today" articles. ⚠️ The home page and a Page call this. An **entry page does not** show the section: it already has its own recirculation. | 1 hr |
| GET | `/widgets/whoop` | sleep/recovery/strain | 5 min |
| GET | `/widgets/plausible/pageviews/:id` | pageview count by Contentful id | 5 min |
| POST | `/api/location` | sets Redis `location:current` + enqueues `LocationSyncJob`, via `Location.store` | — |
| POST | `/api/contact` | drops honeypot hits + enqueues `ContactMailJob`; JSON → 204/422, HTML → 303 | — |
| POST | `/api/build` | enqueues `SiteBuildJob`; 202, or 429 inside the 60s dedupe lock, which `POST /republish` shares | — |
| POST | `/api/icons` | resolves the web build's Font Awesome allowlist to SVGs | — |
| GET | `/api/standard-site` | `{did, publication_uri}` for the build's verification markup | 1 hr |
| GET | `/api/related` | `{contentful id => [related ids]}` from precomputed Voyage embeddings, for the build's static "You May Also Like" section | — |
| POST | `/webhooks/contentful` | enqueues PDS sync, embedding, asset-mirror, and site-build jobs; 204 | — |
| POST | `/webhooks/whoop` | enqueues `WhoopWebhookJob`; 200 `{ok: true}` | — |
| GET | `/whoop/auth`, `/whoop/callback` | Whoop OAuth (authorize is owner-gated) | — |
| GET | `/signin`, `/auth/google_oauth2/callback`; POST `/signout` | owner session | `no-store` |
| GET | `/`, `/spam`, `/location`, `/connected-apps`, `/course-maps`, `/course-maps/:id` | admin UI (owner-session gated) | `no-store` |
| POST | `/spam/:id/not-spam`; DELETE `/spam/:id`, `/connected-apps/whoop` | release or delete a quarantined message; disconnect Whoop | `no-store` |
| GET/POST/DELETE | `/connected-apps/bluesky` | the Bluesky handle + app password form, and disconnect | `no-store` |
| GET | `/location/lookup` | resolves an `address` or a coordinate pair to `{latitude, longitude, place}`. ⚠️ **Never writes** | `no-store` |
| POST | `/location` | same write as `POST /api/location`, coordinates only; answers with the coordinates and the geocoded place | `no-store` |
| POST | `/republish` | starts a build of the web site now, or at a time that the owner picks. The Republish dialog of the nav posts here | `no-store` |
| POST | `/course-maps`; PATCH/DELETE `/course-maps/:id`; GET `/course-maps/status` | upload GPX tracks, save render settings, delete a track, poll publish status | `no-store` |
| GET | `/course-maps/:id/preview`, `/course-maps/:id/download` | the rendered PNG, proxied from Mapbox; same render, only the disposition differs | `no-store` |
| — | `/sidekiq` | job dashboard (owner-session gated) | — |
| GET | `/` (public API host only) | 301 → main site | — |

The Whoop OAuth rows, the owner session rows, the admin UI rows, and the `/sidekiq` row are on the
**admin host only**, wherever `API_HOST` has a value.

⚠️ **`/` is the one path where the two hosts give a different answer**, and where neither one gives a
404. The admin home page is at the root of the admin host, and the public host keeps the redirect to
the main site. Rails draws two routes for `/`, and only the `API_HOST` constraint and **their
order** keep them apart. A change to that order would give the admin UI to the public host, with no
message. `spec/requests/root_spec.rb` and `spec/requests/host_constraints_spec.rb` test both
directions.

## Architecture

### Controllers

There is one namespace for each type of endpoint. Each controller inherits from
`ActionController::Base` directly, and not from `ApplicationController`, thus it does not use the
modern-browser check:

- `widgets/` — `Widgets::BaseController`, with `layout false`, and it includes `LiveWidget`. A widget
  action gets its data from a service, calls `cache_widget(ttl:)`, and then renders an ERB fragment.
  Use `render_empty` when the data is not available: the live-update controller of the site then
  removes the placeholder. Use it and do not raise.
- `api/` — the structured data, below `Api::BaseController`. `ContactController` is the one write
  that a browser can reach, through the web proxy.
- `webhooks/` — one controller for each sending service, below `Webhooks::BaseController`.

**The authentication.** `Widgets::BaseController` and `Api::BaseController` need the `API_TOKEN`
bearer token (`TokenAuthentication`), through a `before_action` for each action. Thus a direct
request to the widget origin fails, with a fast 401 before any work. A new widget endpoint gets that
check when it inherits from the base controller. `standard-site` does not use it: it is public and
the build gets it. A webhook controller does not use the bearer token at all: a sender cannot have
our token, thus each one uses the HMAC method of its own service.

**The owner authentication.** A **Google OAuth** sign-in for one identity controls `/whoop/auth` and
`/sidekiq`, and the bearer token does not. `SessionsController` does the OmniAuth flow and accepts a
login only when the verified email address is `OWNER_EMAIL` and the `hd` domain check passes. It
then puts `owner_email` in the signed cookie session. The `Authentication` concern controls the
Whoop controller, and a small Rack guard in the Sidekiq initializer controls the `Sidekiq::Web`
mount.

### Services

`app/services/`, with `ApplicationService` as the base class. There is one service for each external
API: Intervals.icu, Apple WeatherKit (with an ES256 JWT), Google Maps (`GoogleMaps` finds an address
from coordinates, and `GoogleGeocoder` finds coordinates from an address), Google Air Quality, Google
Pollen, PurpleAir, Whoop (OAuth2), TrainerRoad (iCal), Contentful, Plausible, Font Awesome,
Goodspeed, Akismet, Resend, Turnstile, Voyage (`Embeddings`), `StandardSite`, `AssetMirror`, and
`BlurhashPlaceholder`.
The two article rankings, `TrendingArticles` and `RelatedArticles`, share `ArticleRanking`. Three
more classes hold the parts of the "You May Also Like" score: `ArticleSimilarity` is the vector
arithmetic, `ArticleTaxonomy` is the concept overlap, and `RelatedInspector` makes the two reports
of `rake related:*`. Refer to **The article rankings**.
Five more are not subclasses of `ApplicationService`, because they are not cacheable reads:
`SpamQuarantine`, `TrackLibrary`, and `BlueskyCredentials` use Redis only and no HTTP; `GpxTrack`
parses only; and `MapboxTileset` and `StaticMap` are different (refer to **The course-map
renderer**).
`cached_json(key, expires_in:)` gives the read-through Redis cache. HTTParty makes each request, and
it tries again after a failure. `DeepOstruct` gives dot access.

⚠️ **Plausible permits 600 calls each hour**, and `cached_json` limits each different query body to
one call for its 5-minute TTL. Thus the number of *different queries* is important, and the number of
requests is not. For that reason each `Plausible` aggregate is **one query for the full site**, and
never one query for each article. A query for each article would make one key for each article, and
the number of calls would then grow with the number of articles and go past the limit. **Do not add
a query for each article, and do the calculation again before you make either TTL shorter.**

There are **three different query bodies**, which is 36 calls each hour:

| Method | Dimension | Metrics | Who reads it |
|---|---|---|---|
| `totals_by_path(date_range: "all")` | `event:page` | `visitors`, `pageviews` | the pageviews widget reads the pageviews; `TrendingArticles` and `RelatedArticles` read the visitors |
| `entry_visitors_by_path` (the recent window) | `visit:entry_page` | `visitors` | `TrendingArticles` |
| `entry_visitors_by_path` (the baseline window) | `visit:entry_page` | `visitors` | `TrendingArticles` |

⚠️ **`TrendingArticles` reads the visitors of an ENTRY PAGE, and not the pageviews of a page.** The
trending widget renders on the home page and on each Page. Thus its own clicks go into the pageviews
of an article, and a rank by pageviews put the output of the module back into its own input. At the
traffic of this site that loop can supply most of the recent traffic of an article. A session that
*starts* on the article measures the demand from outside the site, and no click inside the site can
change it. Do not change this back to `event:page`.

⚠️ **`totals_by_path` gives two metrics from one query body, on purpose.** Two queries would cost two
keys for the same data. `pageviews_by_path` is a small wrapper over it.

**The types of failure that you must know:**

- Most services give a smaller result on a failure: the widget goes away and the code does not raise.
- `Akismet` fails **closed** when it has a configuration: a failure of the service raises, thus the
  intake job runs again. It permits the message only when it has no configuration. `Turnstile`
  permits the message on a failure.
- `AssetMirror` **raises**, thus Sidekiq does the job again. An asset that the code does not copy,
  with no message, becomes a broken image on a live page later.

### The R2 image mirror

`AssetMirror` copies each published Contentful **image** asset into an R2 bucket, and the `web/`
build changes each asset URL to the custom domain of that bucket. ⚠️ **This is a data contract
between the two apps, and neither side checks the other.** The full text is in the root
[`CLAUDE.md`](../CLAUDE.md).

- **It copies a publish only.** ⚠️ An unpublish and a delete do not remove the object, on purpose:
  the web build reads Contentful with a **preview** token, thus a page from the build still points
  at an unpublished asset. The content gives the key of each object, thus each object is immutable
  and nothing needs an invalidation.
- ⚠️ **The download uses `Net::HTTP#read_body`, and not HTTParty. Do not change it to the usual
  style.** These originals are as large as 38MB, and the worker is a **512MB** VM at **concurrency
  5**. Full files in memory caused an OOM kill during the first backfill, and a hard kill is not a
  failure that Sidekiq can do again. Thus the jobs in progress went away with no message: nothing
  copied 13 assets, and those assets showed only as a 404 on a live page. HTTParty does not correct
  this, even with `stream_body: true`: a measurement gave +52.3MB peak RSS against +1.2MB for the
  stream loop. The Tempfile is necessary for the same reason: it lets the S3 client upload from the
  disk and not from a second copy in memory. If the asset library gets many more large originals,
  make the VM larger before you increase the concurrency.
- **`rake assets:backfill`** adds one job for each asset, and each job does nothing for an asset that
  is already in the bucket: one HEAD, and no data transfer. Thus it is cheap to run again, and it is
  also the reconciliation net for the webhook deliveries that Contentful never sends again.
  `DRY_RUN=1` gives the count. ⚠️ Run it to its end **before** `IMAGE_HOST` gets a value on the web
  side.
- It does nothing when the `R2_*` vars are absent, thus it stays inactive in development and in
  CI.

### The card cover image

The trending card renders the cover image of the article. Two parts make it:

- **`config/srcsets.yml`** holds the shape (`ratio`, as `"16:9"`), the `sizes`, and the candidate
  widths of the card. It is a copy of
  `web/data/srcsets.yml`, word for word, and `ImagesHelper` reads its `card` variant one time at
  boot. ⚠️ Copy the full file (`cp web/data/srcsets.yml api/config/srcsets.yml`), and do not copy
  the `card` block alone: `spec/contracts/srcsets_contract_spec.rb` compares the two files and
  fails on each difference. That file also gives the method that makes the widths.
  ⚠️ **`ratio` is the ONE place that holds the shape of a card.** Both apps read it for the `h` of
  each candidate, and both write it into the markup as the `--card-ratio` custom property, which
  `.entry__cover-image` in `_entry.scss` and `.entry-skeleton-cover` in `_skeleton.scss` read. Thus
  a change to the shape is one edit and one `cp`. Never write a number in a stylesheet or in a
  helper.
- **`ImagesHelper`** makes the URL: `<IMAGES_URL>/cdn-cgi/image/<options>/<mirror url>`. It changes
  each `*.ctfassets.net` host to `IMAGE_HOST`, which is the R2 mirror, as the web build does. ⚠️ It
  returns nil when either variable has no value, and it never raises: a raise here gives a 500 and
  leaves an empty skeleton on the home page. ⚠️ It never falls back to a ctfassets URL. Such a URL
  gets a 403 as a transformation source, and it uses the metered Contentful bandwidth as a direct
  `src`.
- **`BlurhashPlaceholder`** makes the small blurred SVG that shows before the image loads.
  `AssetBlurhashJob` does that one time for each asset, off the asset-publish webhook, and
  `rake blurhash:backfill` does it for the assets that exist. The view then reads one Redis key,
  `blurhash:svg:<asset id>:<published version>`. ⚠️ The job gets its 32-pixel thumbnail from the
  **Contentful Images API**, and not through the mirror: a mirror fetch would make it wait for
  `AssetSyncJob`. Thus an asset on `downloads.ctfassets.net`, which has no Images API, gets no
  placeholder, and the card then shows the flat colour.

⚠️ **This needs `libvips` at run time**, through the `ruby-vips` gem. `libvips42t64` is in the
**base** stage of the Dockerfile, and not in the build stage: the final stage is `FROM base` and it
copies only `/rails` from `build`. ⚠️ The name has the `t64` suffix because `ruby:<version>-slim` is
Debian **trixie**, and the 64-bit `time_t` transition renamed the package. On bookworm it is
`libvips42`. ⚠️ The `blurhash` gem is the **fork** at `github.com/gesteves/blurhash`,
at the same ref as `web/Gemfile`. The rubygems release has `encode` only, and this code needs
`decode` and `valid_blurhash?`.

⚠️ **Set `IMAGES_URL` and `IMAGE_HOST` as fly secrets, then run `rake blurhash:backfill`.** Without
the two variables the card renders no image at all. Without the backfill each card shows the flat
colour until a person publishes its asset again.

### The article rankings

Two modules put articles in order, and each one has its own rules.

**`TrendingArticles`** reads the entry-page visitors of two moving windows and gives each article a
score. Read the ⚠️ above about `visit:entry_page`.

- ⚠️ **The prior goes on BOTH sides of the surge ratio** (`(recent + PRIOR) / (expected + PRIOR)`).
  It moves a ratio from a small count toward 1, which is "no surge". With the prior on the divisor
  alone, an article with no baseline and 5 visitors got a surge of 5, and a true surge looked
  exactly the same. This is the one change that makes the score correct at the traffic of this site.
- ⚠️ **The floor is adaptive**: it is a percentile of the articles that got any traffic, and never
  less than `ABSOLUTE_MIN`. Thus no person tunes a number when the traffic changes. It drops back to
  `ABSOLUTE_MIN` when fewer than `MIN_ABOVE_FLOOR` articles go past it, because a quiet week must
  not empty the widget.
- ⚠️ **`MIN_ABOVE_FLOOR` is a constant and not the `count` of the caller.** The cache holds one list
  for each hour and each caller shares it. A `count` there would make that list different for each
  caller below one key.
- ⚠️ **The group with a score of 0 goes in the order of the visitors of all time, and not the date.**
  The widget renders on the home page, which already lists the new posts. Thus a fallback by date
  made the widget a copy of that list. The date stays as the last key only because `sort_by` is not
  stable.
- ⚠️ **Each new setting must go into `#ranking_version`.** That digest is the cache key. A setting
  outside it leaves the previous list in the cache for its full hour, below a key that looks
  correct.

**`RelatedArticles`** reads the stored Voyage vectors and gives each candidate a score. The request
path never calls Voyage.

- ⚠️ **`ArticleSimilarity.prepare` subtracts the mean vector of the corpus.** This is what makes the
  ranker operate. The corpus has one author, one domain, and one genre, thus each vector holds a
  large shared component and the similarities group into a narrow band where the order is near to
  noise. The subtraction removes that shared direction. It also makes each vector a unit vector, thus
  a similarity is a dot product: the old cosine calculated the norm of the same vector some hundreds
  of times.
- ⚠️ **The concept overlap uses an IDF weight.** "Race Reports" is on most articles and gives almost
  no information, and "Ironman Canada" is very specific. A plain Jaccard would let the common
  concepts control the result, and each article would look related to each other article.
- ⚠️ **The floor reads the relevance and not the score.** The score holds the small addition for the
  date and the popularity. A new or a popular article that is not related must never go past the
  floor because of that addition. `MIN_SCORE` is 0 and it is exclusive: after the mean subtraction,
  the mean similarity of a pair is near 0, thus a score at or below 0 means "not related".
- ⚠️ **The floor selects which candidates to PREFER, and it never makes the list short.** `mmr_pool`
  takes each candidate above the floor, then fills the rest from the best of the others. The section
  renders a two-column grid, thus a list of three leaves a hole. An earlier version made the section
  short, or absent, when each candidate was below the floor. A Short with few near articles then
  showed three cards.
- ⚠️ **The same-race demotion is a demotion and never an exclusion.** A Short renders
  `_related.html.erb` with no "More Reports From This Race" section above it. It is also small on
  purpose: a shared rare concept is true relatedness, and it wins against the demotion. **MMR** does
  most of the work to go wider, because four reports of one race are near-copies of each other.
- ⚠️ **`TaxonomyConcepts.ancestor_ids` is not named `ancestors`.** That name is a method of Module,
  and Rails and RSpec both call it on a class. It also copies the `broader` list, because `Array()`
  gives the same object back and the queue changed the tree of the caller.

**The inspection tools.** ⚠️ No A/B test can operate at the traffic of this site. Thus
`rake related:inspect[slug]` and `rake related:audit` are the only method to know if a change to the
ranking helped. The audit gives the spread of the similarity **before and after** the mean
subtraction, and that number decides if the corpus needs an embedding for each chunk of a body. It
also names each entry whose stored embedding is older than the entry: Contentful never sends a
webhook again, thus `rake embeddings:backfill` is the only correction.

### Webhooks

`Webhooks::ContentfulController` takes each publish, unpublish, and delete event, and
`ContentfulRequestVerification` checks its HMAC. That controller **only adds jobs to the queue** and
returns a 204, and the Sidekiq worker does the work. At each publish it adds the standard.site sync,
the article embedding, the R2 asset copy, the blurhash placeholder, and **`SiteBuildJob`**, which
builds the web site again.
Set the Contentful webhook to a publish, an unpublish, and a delete of an **Entry and an Asset**,
thus a change to an image also starts a build. Do **not** include an automatic save. ⚠️ Contentful
does **not** send a delivery again. `rake standard_site:backfill`, `rake assets:backfill`, and
`rake blurhash:backfill` are the reconciliation paths.

`Webhooks::WhoopController` takes the Whoop v2 webhooks. `WhoopRequestVerification` checks them with
the HMAC method of Whoop: `WHOOP_CLIENT_SECRET` signs a base64 HMAC over the timestamp and the raw
body, and the timestamp can be 5 minutes before or after the current time. The controller also
compares the `user_id` in the payload with the authenticated athlete. Redis holds that id for a day,
and a different user gets a 403, thus Whoop stops. The controller adds a job to the queue and
answers with a 200, in the approximately 1 second that Whoop needs. Register the URL with **Model
Version V2** in the Whoop dashboard.

`WhoopWebhookProcessor` writes the custom wellness fields `WhoopStrain`, `WhoopSleepPerformance`, and
`WhoopRecovery`, and the activity field `WhoopWorkoutStrain`. ⚠️ All four must exist in Intervals.icu
at Settings → Custom Fields. Without one of them, the code writes a 422 to the log and does no more.
The processor then adds a separate `ActivityDescriptionJob` to the queue. The two jobs are separate,
on purpose: if the Whoop integration goes away, the metric sync stops but the descriptions continue
to work, and only the 🔥 line is absent.

### Background jobs

**Sidekiq** directly (`Sidekiq::Job`, and not ActiveJob), in `app/jobs/`. Each job inherits from
`ApplicationJob`, a plain parent class that holds the shared `retry_for: 24.hours`: Sidekiq waits
the usual time between two attempts, then puts the job in the Dead set 24 hours after its first
failure. Each job takes plain strings as its arguments, and you can do each job more than one time.
Thus that shared window is safe.

| Job | What |
|---|---|
| `StandardSiteSyncJob(operation, entry_id)` | standard.site PDS sync |
| `AssetSyncJob(asset_id)` | Copies one image asset into R2. ⚠️ It raises and does not give a smaller result. |
| `AssetBlurhashJob(asset_id)` | Makes the blurhash placeholder of one image asset. It fails soft. |
| `ArticleEmbeddingJob(operation, entry_id)` | keeps an article's Voyage embedding in sync |
| `SiteBuildJob(event_type)` | fires a GitHub `repository_dispatch` to rebuild the web site. ⚠️ The one job that a caller schedules, with `perform_at` |
| `WhoopWebhookJob(event_type, resource_id, trace_id)` | syncs Whoop metrics to Intervals.icu |
| `ActivityDescriptionJob(activity_id, whoop_strain = nil)` | (re)generates an activity's Strava description and tidies its name |
| `LocationSyncJob(latitude, longitude)` | propagates the current location to Intervals.icu |
| `ContactMailJob(name, email, message, context, restored_from_spam = false)` | contact intake: Akismet + compose |
| `ContactDeliveryJob(payload)` | the one retryable *delivery* unit — sends via Resend |
| `MapTilesetJob(id)` | publishes an uploaded GPX track to Mapbox as a vector tileset |
| `WhoopTokenRefreshJob()` | forces a Whoop token refresh on a schedule (see below) |

- **`SiteBuildJob`** has three callers, and each one has its own event type: the Contentful webhook
  sends `contentful-publish`, `POST /api/build` sends `api-build`, and the Republish dialog of the
  admin sends `admin-republish`. The three builds are the same, and the three types exist only to
  let the Slack notification of the deploy name the cause. ⚠️ **The `repository_dispatch.types` of
  that workflow must keep all three types.** GitHub accepts an event with a type that is not in that
  list, answers with a 204, and runs nothing, and it gives no message. The event type is always a
  constant from the caller, and never a request parameter. The job does nothing when
  `GITHUB_DISPATCH_TOKEN` or `GITHUB_REPOSITORY` has no value.
  - **The trigger lock is on this class**, as `TRIGGER_LOCK_KEY` and `.claim_trigger_lock`. The two
    manual callers — `POST /api/build` and the Republish dialog — share that 60-second window. Thus
    a double click, or a click after a `curl`, cannot start two Actions runs. ⚠️ The Contentful
    webhook must never take it: a publish inside the window would go away with no message.
  - **This is the one job that a caller schedules.** The Republish dialog uses `perform_at`, which
    puts the job in the scheduled set of Sidekiq. The Scheduled tab of `/sidekiq` lists it, and it
    is the only place that can cancel it.
- **`ActivityDescriptionJob`** does not know its source. It writes the stat lines with an emoji: the
  power, the heat, the Whoop strain, and the water temperature. It also writes two lines that
  Anthropic makes: a summary of the planned workout, which the code matches against the TrainerRoad
  calendar, and a weather sentence. The prompts are in `app/prompts/`, and the job omits those two
  lines with no `ANTHROPIC_API_KEY`. It keeps the text that the user wrote above the stat block. A
  Redis lock stops a second job for the same activity. The same PUT also corrects a name from Rouvy
  (`ROUVY - <route> - <date>` becomes `Rouvy - <route>`), thus it can write even when the
  description is empty.
- ⚠️ **Turnstile protects the JSON path only** (`request.format.json?`). Thus a POST from a script
  with no `Accept: application/json` does not do that check. We read this and **accepted** it: the
  widget needs JavaScript, and a check on both paths would stop the path with no JavaScript. The
  things that truly stop an attack are the honeypot, Akismet, which fails *closed* when it has a
  configuration, the length limits, and the throttle of 5 each hour on `X-Kona-Client-IP`. Do not
  remove one of those, and do not assume that Turnstile does that work. To close this gap, the path
  with no JavaScript needs a second factor also, for example a signed token with an expiry time that
  the server puts in the form.
- **The contact form uses two jobs**, thus a Resend failure repeats the send only. Akismet fails
  closed, thus a failure of that service makes the *intake* job run again and the app does not
  deliver a message with no check. `ContactSubject`, which makes a subject line with Claude, fails
  soft. A message that Akismet marks goes to the **quarantine, and the app does not remove it**
  (refer to **The spam quarantine**). `restored_from_spam` means that the owner sends such a
  message: the code then does no check and tells Akismet that the mark was incorrect.

The configuration is in `config/initializers/sidekiq.rb` and in `config/sidekiq.yml`. Sidekiq runs
as its own **`worker` fly process**. A worker must run, or nothing does the queued jobs. On your own
machine, use `bundle exec sidekiq`.

**The recurring jobs** come from `sidekiq-scheduler`. Its schedule is below `:scheduler:` in
`config/sidekiq.yml`, and it starts in the Sidekiq **server** only. Puma loads the gem and schedules
nothing, thus no job runs two times across the two fly machines. Its "Recurring Jobs" tab is on the
`/sidekiq` dashboard, which the owner session controls. Today there is one scheduled job,
`WhoopTokenRefreshJob`, each 6 hours. Whoop rotates its refresh token at each refresh, and it makes
a token with no use expire. In all other conditions the app refreshes a token **only when it is
necessary**. Thus a quiet period, with no widget traffic and no webhook, would leave the integration
in a state that needs a manual authorization at `/whoop/auth`. The job calls
`Whoop#refresh_tokens!`, which does not use the access-token cache but which still takes the same
refresh lock. When Whoop refuses the token, the Connected apps page shows the failure, and Bugsnag
is not the only record. Refer to the text below. ⚠️ **Each schedule entry must use `cron:`, and not
`every:`.** rufus measures an `every` interval from the start of the process, thus a 6-hour interval
starts again at each deploy and can go for a long time with no run.

### Views, helpers, presenters

A view in `app/views/widgets/` renders a plain HTML fragment. Each **helper** in `app/helpers/` is a
format function or a selection function: each method takes its data as an argument, and no method
reads an instance variable of a controller. The state of a request is in a **presenter**
(`app/presenters/`): `WeatherSummaryPresenter` has the text and the rules of the weather widget, and
there are also `EventWeatherPresenter`, `UpcomingRacesPresenter`, and `WhoopPresenter`. Each
presenter takes its data as constructor keyword arguments. When the body of a controller needs a
helper, it calls that helper through the `helpers` object and it does not `include` the module.

### The admin UI

An admin UI for the owner, with **Web Awesome Pro** components. It is the one part of this app with
an asset pipeline, a layout, and JavaScript in the browser. Each other part still renders a
`layout false` fragment.

⚠️ **Its routes are at the ROOT, and not below `/admin`.** Rails draws them on the admin host only,
where that prefix would repeat the host name. `scope module: "admin"` in `config/routes.rb` keeps the
controllers together below `Admin::` and does not put that word in the path. The result is that each
admin page uses a top-level path. Read each new page against the scanner-noise custom rule of the
zone: that rule blocks full prefix families (`/config/`, `/home/`, `/analytics/`, `/deploy/`, and
more) in the full zone, and it would give a 403 to a page with one of those names. Add the prefix of
each new page to `RACK_ATTACK_KNOWN_PREFIXES` also.

**The stack: Turbo, Stimulus, and Web Awesome, and the server renders each page.** There is no SPA
framework and no separate front-end app, on purpose, and not because the plans are small: a maps UI,
a daily dashboard, and, later, a replacement for Contentful all belong here. Web Awesome already has
the admin components that those need, and one set of components across `web/` and `api/` is what
keeps the design system as one. When one screen truly needs state in the browser, add it as an
**island**: install the npm package, import it in `app/javascript/admin.js`, and start it from the
`connect()` of a Stimulus controller. The pipeline accepts that with no change.

**The pipeline**: Propshaft adds the fingerprint, jsbundling-rails runs `npm run build` in
`assets:precompile`, and esbuild makes the bundle. The esbuild configuration is in
`esbuild.config.mjs` and not in CLI flags, and `web/` uses flags. The reason is that the code must
register the Sass plugin in the same process. `app/javascript/admin.js` is the one entry point.
esbuild writes `app/assets/builds/admin.js` *and* an `admin.css` beside it, from the stylesheet
imports. The bundle is necessary because the `dist/` of Web Awesome imports `dist/chunks/*.js` with
a relative path, and Propshaft changes no import path.

**The styles are Sass**, with one BEM block in each partial below `app/javascript/styles/`, and
`admin.scss` imports them. ⚠️ **esbuild makes `webawesome.css` into one file, and Sass does not.**
That file is a group of `@import url(...)` statements, and Sass keeps each one as a plain CSS
import. Thus the stylesheet from the build would point at paths that do not exist. For that reason
the vendor stylesheet stays a plain `.css` import in `admin.js`, before our `.scss`.

- ⚠️ **Each `npm ci` needs `WEBAWESOME_NPM_TOKEN`**: your shell, the GitHub runner, and the **remote
  builder of fly** (`flyctl deploy --build-secret`, and that is the reason for the flag in the
  deploy command). `.npmrc` reads it from the environment, and it is never on the disk.
- ⚠️ **The build stage of the Dockerfile deletes `node_modules` at its end.** The final stage does
  `COPY --from=build /rails /rails` for the full directory, thus each file that stays goes to a
  512MB VM.
- ⚠️ **The import of the full `styles/webawesome.css` is necessary**, and it is not for convenience.
  `styles/layers.css` defines `.wa-mobile-only` and the rule that hides `[data-toggle-nav]` on the
  desktop, and `styles/utilities/fouce.css` gives `.wa-cloak`. A selection of the theme only, as
  `web/` does, removes both, and it gives no message. The code imports our Sass *after* it, and our
  Sass has no layer. Thus our Sass wins over each `wa-*` layer, and it needs no change to its
  specificity.
- ⚠️ **Do not use `<wa-icon>`.** It finds each icon through a base path or a Font Awesome kit code,
  and neither one is in this configuration. The npm package has no icon file, thus each icon is
  empty and it gives no message. Use `icon_svg(family, style, id)`, and **always with `raw`**: it
  returns a plain String, and without `raw` ERB escapes the markup and the page shows it as text.
  For an icon in a slot of a component (`start` or `end` on `<wa-button>`, and `icon` on
  `<wa-callout>`), use `slotted_icon_svg(family, style, id, slot:)`, which returns a safe buffer and
  needs no `raw`.
- ⚠️ **ARIA on a `wa-*` host does not reach the element in its shadow root.** `<wa-button>` renders
  its own `<button>` or `<a>`, and it sends `href`, `target`, `rel`, and `type` to that element but
  no ARIA. `icon_svg` also marks each SVG `aria-hidden`. Thus an `aria-label` or an `aria-current`
  on the host does nothing for a screen reader. Put the name or the state in the **content of the
  slot**, in a `wa-visually-hidden` span. The button in the header and the current item of the nav
  both do that. Turbo is different: it *does* go into a shadow root and out of it. It finds the
  anchor in a `wa-button` through the composed path of the click, and it then finds
  `data-turbo="false"` on the host. Thus a `<wa-button href>` navigates with Drive, as a plain link
  does.
- ⚠️ `rake assets:*` now has two groups: `assets:backfill`, which is the R2 image mirror above, and
  the `assets:precompile`, `assets:clean`, and `assets:clobber` of Propshaft. There is no conflict,
  but the two groups have no relation.

**Use a Web Awesome component in place of a native element wherever one exists.** Use its layout
utilities (`wa-stack`, `wa-cluster`, `wa-grid`, `wa-gap-*`, and `wa-visually-hidden`) and its design
tokens (`--wa-space-*`, `--wa-color-*`, and `--wa-form-control-*`) in place of CSS that a person
writes. In practice that means **no** `button_to`, which writes a native `<button>`. Use `form_with`
around a `<wa-button type="submit">`. The button of Web Awesome is part of its form
(`formAssociated = true`), thus it submits that form as a native button does, and this includes the
CSRF token and `_method`. A plain `<button` in the server HTML means that one came back into the
code, and two request specs check that there is none.

Use Sass here for what is truly ours: the layout of one page, the brand colors, and a border that
the component does not draw. A rule that repeats the appearance of a component — its corner radius,
its hover color, its focus ring, or the height of a control — means that a person did not use the
API of that component. Use `appearance`, `variant`, or `size` first, then its CSS custom properties,
then `::part()`, and write your own rule last. The same applies to the markup: when a `wa-*` element
appears to have no method for something, read its documentation before you make your own code. More
than one difficult part here is documented behavior: the navigation slot of `<wa-page>`, the form
association, and `::part(base)`.

⚠️ **The package has its own documentation. Read it, and do not use an API from memory.** That
documentation is the source of the examples of the vendor, and its version is the version that you
installed:

- The **`webawesome` skill** is available in this environment. Use it for the API of a component,
  that is, its attributes, its slots, its parts, and its events, and for the list of the utilities
  and the tokens.
- Both skills are on the disk at `node_modules/@web.awesome.me/webawesome-pro/dist/skills/`. There is
  one `webawesome/references/components/<name>.md` for each component, and `webawesome-design/`
  covers the layout and the theme. The `<wa-page>` rules below come from
  `webawesome-design/references/layouts-page.md`.
- When neither one has the answer, read the source and the styles of the component
  (`dist/components/<name>/` and `dist/chunks/*.js`). That is the only place with the shadow-DOM
  behavior above.

**The brand color** is the firebrick of the site (`#bf0222`, the same as `--color-firebrick` in
`web/`). Web Awesome makes each brand surface from the `--wa-color-brand-NN` ramp, thus there is no
single token to set. The layouts put **`wa-brand-red`** on `<html>`, which is the supported method of
Web Awesome to change the full ramp to the red family and to keep its hover step and its quiet step
at a good contrast. `styles/_tokens.scss` then sets `--wa-color-brand-50`, the step of the *loud*
surfaces, to the exact firebrick. That color is also the color of the Turbo progress bar and of the
logo on hover. ⚠️ Do not write the other ten steps of the ramp by hand, because the palette gives
the correct values.

**The layouts** are `layouts/admin.html.erb`, which is the `<wa-page>` shell, and
`layouts/auth.html.erb`, which is the sign-in page and has the Google button only, with no heading
and no text. Both use `layouts/_head.html.erb`. ⚠️ **Neither one has the name `application`**,
because that is the implicit default of Rails. This app is for machines by default, thus each
controller that exists must stay the same even if a person removes a `layout false`. The dark mode
comes from an inline script that changes `prefers-color-scheme` into the `.wa-dark` class of Web
Awesome. The styles use that class, and not the media query.

**The `<wa-page>` rules** (the package has its own reference at
`dist/skills/webawesome-design/references/layouts-page.md`): write the nav **one time** in
`slot="navigation"`. The component moves that one copy between the sidebar of the desktop and the
drawer of the mobile, thus a second copy shows two times on the desktop. `--menu-width` must go back
to `auto` for `view='mobile'`, or an empty band stays at the left. Each nav link needs
`data-drawer="close"`. ⚠️ Set `disable-navigation-toggle` in the markup, because the server renders
the page: the component sets it when it sees our `[data-toggle-nav]`, but not before it upgrades.
Until then its own hamburger button shows on a row with no style above the header.

⚠️ **Two flows must refuse Turbo** with `data-turbo="false"`: the Google sign-in form and the
**Connect** link of Whoop. Both are same-origin URLs that redirect to a different origin, and Turbo
Drive cannot follow that. It fails with no message, and the click appears to do nothing. The
Connected apps view puts the attribute on the Connect button of each card. For a card whose path is
an ordinary admin page, which is the form of Bluesky, the only cost is a full page load.

The header has the wordmark of the site, `layouts/_logo.html.erb`, which is a **copy word for word**
of `web/source/partials/_logo.svg.erb`. ⚠️ Its paths contain `fill="#020a0a"`, which you cannot see
on the dark theme. `_admin-header.scss` changes that to `currentColor`, and that is also the reason
for the inline SVG in place of an image: an `<img>` cannot take the color of the text. A difference
between the two copies costs no more than an old admin logo.

The sidebar comes from `AdminHelper`: `#admin_nav_items` gives the three items with no group, which
are Home, Republish site, and Spam, and `#admin_nav_groups` gives the groups with a caption, which
are Tools, Settings, and More. Both render through `layouts/_admin_nav_item`, thus the code for the
drawer, the active state, and the icons is written one time. Each item is a
`<wa-button appearance="plain" href>` with an icon at its start, and the item of the current page is
`filled`. Thus the active state is a step of Web Awesome, and not a background color that a person
selected. An item with `external: true`, which is Sidekiq only today because it renders its own
layout, opens in a new tab with `rel="noopener"` and a hidden "(opens in a new tab)".

⚠️ **An item with `dialog:` is an action and not a destination**, and it has no `:path`. It renders
as the same button with no `href` and with `data-dialog="open <id>"`. It keeps `data-drawer="close"`,
thus one tap on a phone closes the drawer and opens the dialog: both attributes have a handler on the
document. **Republish site**, directly below Home, is the only one today. It opens
`layouts/_republish_dialog`, which the layout renders one time, and `POST /republish` then starts a
build of the web site, now or at a time that the owner picks. The rules of that dialog:

- ⚠️ **It is a sibling of `<wa-page>`, and not a child.** That component moves its
  `slot="navigation"` content between the sidebar and the drawer, and the dialog must not travel
  with it.
- ⚠️ **The two footer buttons are outside the `<form>`.** A slot takes a direct child of the dialog
  only. `form="republish-form"` joins the submit button to that form, because `<wa-button>` is
  form-associated and reads that attribute as a native control does.
- ⚠️ **The browser gives the time zone**, and the `republish` controller fills the date and the time
  with the current *local* values. It must never use `toISOString()`: that method gives UTC, and the
  fields would then show a time that the owner does not have on the clock. This app declares no
  `config.time_zone`, thus the UTC fallback of the server means only that the script did not run.
- ⚠️ **A time that has already passed builds now, and it is not an error.** The dialog can stay open
  past that moment. To refuse it makes the owner type the time again for the build that they already
  asked for.
- ⚠️ **`RepublishController` matches the shape of the date and the time before it parses them.**
  `Time#parse` is permissive: it reads `"not-a-date 06:30"` as 06:30 today, and that time has passed,
  thus text with a mistake would start a build. `MAX_HORIZON`, which is 90 days, guards the other
  side: a year with a mistake would park a job in Redis for decades.

A group is only a caption above its own `<ul>` of those same links:

- ⚠️ **The caption is a `<div>`, and not a heading element.** It is above the `<h1>` of the page,
  thus a true heading would come before that `<h1>` in the outline of the document. The `<ul>` has
  an `aria-labelledby` that points at the caption, and that is what joins the two for a screen
  reader.
- ⚠️ **`_admin-nav.scss` makes the icon box of each item square**, against the `width: auto` that
  `_base.scss` gives to each inline SVG. The viewBox of a Font Awesome icon is not always square,
  thus at an automatic width no two labels in the column start at the same x.

**Connected apps** (`/connected-apps`) connects Whoop and Bluesky and disconnects them.
`ConnectedAppPresenter` renders four states from a `valid_credentials?` and `connected?` pair and an
optional `error:` string. The fourth state, `:error`, means connected but broken, and it gives
**both** Reconnect and Disconnect. A new authorization is the correction, and a rule to disconnect
first would remove the one thing that makes this state different from a new setup.

- **Whoop** uses OAuth, and `Whoop#disconnect!` removes the tokens. ⚠️ It also deletes the cached
  `user_id`, because `Webhooks::WhoopController` authorizes each payload against it. A copy that
  stays continues to accept a webhook for an account with no tokens.
  - ⚠️ **A refused refresh keeps the tokens.** Thus `connected?`, which asks only if a refresh token
    exists, continues to say true while nothing operates. `Whoop#record_refresh_error` writes
    `whoop:<client id>:refresh_error` for a **4xx** from the token endpoint, and `#refresh_error`
    makes the card show that. **A 4xx only**: a 5xx or a timeout means that Whoop is down, and a
    message for those sends the owner to authorize credentials that are correct. `store_tokens`
    clears it, thus a refresh or a new authorization that is successful clears it, and `disconnect!`
    clears it also.
- **Bluesky** has no OAuth round trip, thus it connects with a form at `/connected-apps/bluesky`.
  `Admin::BlueskyController` has all three of its actions and does not put the disconnect on
  `connected_apps#`. `BlueskyCredentials` keeps the handle and the app password in the Redis hash
  `bluesky:credentials`. ⚠️ **That page is the only method to set them, and there is no environment
  variable.** Thus the integration does nothing in a new environment until a person connects it.
  - ⚠️ **The code encrypts the app password at rest** with `ActiveSupport::MessageEncryptor` and
    `secret_key_base`. That password is a credential for the full account, it operates from any
    client, and this Redis also holds the Sidekiq queues. It is the only encrypted value in the
    app. A failure to decrypt returns nil and does not raise, thus a new `RAILS_MASTER_KEY` gives
    "not connected" in place of an error on each page that shows the status.
  - ⚠️ **`StandardSite#connect!` checks the credentials before it stores them**, and it opens a true
    PDS session. An app password with a mistake, stored with no check, fails with no message at the
    next publish.
  - ⚠️ **`disconnect!` keeps `standard_site:did`, on purpose.** The DID is public data and not a
    credential, and `GET /api/standard-site` gives the verification `<link>` tags of each page of
    the static site. To clear it removes those tags from the full site at the next build, below a
    60s cache, and that never looks like a problem at the edge.
  - ⚠️ **A change of the DID makes the fingerprint of the publication record incorrect.** The
    fingerprint of a document covers the `at://` URI of the publication, which contains the DID,
    thus each document fingerprint becomes invalid by itself when the account changes. The
    fingerprint of the publication record does not, and an old one reports `:unchanged` for ever and
    never syncs to the new repo.
  - ⚠️ **To flush Redis costs a new connection**, because the credentials are only there and no
    other code can make them again.

### The spam quarantine

**Spam** (`/spam`) lists each message that Akismet flagged, the newest first, with **Not spam** and
**Delete forever**. `ContactMailJob` does not drop a flagged message: it stores it with
`SpamQuarantine`. **Not spam** enqueues that job again with `restored_from_spam`, which does not do
the check and which calls `Akismet#submit_ham`.

- **There is one Redis hash**, `contact:spam`, and each field name is an id that the code makes.
  There is no key for each message, on purpose: no other code here reads the full keyspace, and this
  Redis also holds the Sidekiq queues, thus a `SCAN` would be the first one. ⚠️ The result is that
  Ruby applies the 30-day retention. Thus `#store` removes old messages, and `#all` also does.
  **The removal on the write path is what keeps the size small when nobody opens the page.**
- ⚠️ **`SpamQuarantine#take` reads and removes, and the return value of `HDEL` is the guard.** Turbo,
  a double click, or a replay from the bfcache can start "Not spam" two times. To release on the
  read alone sends the email two times.
- ⚠️ **`Akismet#submit_ham` fails soft, which is the opposite of the rest of that class.** `#spam?`
  raises, thus no message goes out with no check. The ham report is training only, and it must never
  stop a message that the owner already judged to be good.
- ⚠️ **These cards are the only input from an attacker that this app renders as HTML with no
  filter.** The default escape of ERB is the full defense: use no `raw`, no `html_safe`, and no
  `simple_format` on a message field. The `raw icon_svg(...)` pattern of each other admin page must
  not come here. `white-space: pre-wrap` gives the line breaks. A request spec pins this with a
  `<script>` payload.
- ⚠️ **The "do not use `<wa-icon>`" rule does not apply to `wa-details` and `wa-dialog`.** Their
  chevron icon and close icon use `library="system"`, which gives inline data URIs from the
  component itself, and no kit code. The delete confirmation is fully declarative
  (`data-dialog="open <id>"` and `data-dialog="close"`), and the `dialog` Stimulus controller only
  closes the dialog before Turbo caches the page.
- The **Delete forever** button of the card is `variant="neutral"` and not `danger`, because the
  brand ramp here *is* red. A danger variant beside the "Not spam" button in the brand color makes
  the safe action the loudest part of the card. Red is for the confirm button in the dialog only.

### The location picker

`/location` has two columns: the controls at the left and a Mapbox map at the right, and one column
below 60rem. Four controls **stage** a location and none of them writes: a drop or a drag of the
pin, an address in the box, a reading from the Geolocation button of the map, and a race from the
shortcut list. **Save**, below the place name and the coordinates, is the only control that writes.
**Undo**, beside it, removes the staged pair and puts the pin, the map, and the heading back to the
stored values. Both controls are disabled when the staged pair is equal to the stored pair. A
`wa-badge` beside the coordinates gives that state — Saved, Unsaved, or "Not set" before a location
exists — in the same outlined form that Connected apps and Course maps use.
⚠️ `LocationPresenter#state_label` and `#state_variant` render the first state, and `STATES` in
`location_map_controller.js` renders each state after that. The two lists of words must agree.

- **The page writes through `Location.store`**, which is the method that `POST /api/location` uses.
  Thus the two cannot become different in their order (Redis first, then the sync) or in their check
  (`Location.parse`, which uses `Float()` and not `to_f` — read the Null Island ⚠️ there). This page
  is a front end over the write of that endpoint, and not a second method to store a location.
- **The heading is the output of `format_location`**, which is the same helper over the same
  `GoogleMaps#location` that `WeatherSummaryPresenter` renders. Thus the page is also a preview of
  the name in the weather widget. ⚠️ It is not `LocationContext#label`, which adds a fallback
  ("Current location") that the widget does not have. Such a preview would show a name that the
  widget never prints. When the geocode gives no result, the page shows the coordinates.
- ⚠️ **`GET /location/lookup` must never write.** It stages a location: it geocodes an address, or
  it names a pair of coordinates for the preview in the heading. The full value of the Save button
  is that no step before it changes what the widgets read. A request spec runs each lookup example
  with a `$redis.set` that raises.
- **Undo restores from memory, and not from the server.** The controller keeps the place name of
  the stored pair from the last response that set it, thus to remove a change costs no lookup.
  ⚠️ When nothing is stored, Undo puts back the line that the *server* rendered, which the
  controller captured at connect. To write "Drop a pin on the map…" and "Not set" again in JS is
  exactly the text that would become different.
- **`POST /location` accepts coordinates only.** The lookup resolves an address first, thus this
  code stores one shape of data and one place decides what a correct location is.
- ⚠️ **Both responses contain the place, and the page makes the heading again from that.** The name
  that the server rendered describes the location at the *load* of the page, and one drop of the pin
  makes it a caption for a different place. ⚠️ The save path marks the pair that it *sent* as
  stored, and not the pair that is staged when the response comes back. The pin can move again, and
  to mark that pair as stored disables Save while a change is not saved.
- ⚠️ **The page rounds the coordinates that it shows, and the code for that is in two places**:
  `LocationPresenter::DISPLAY_PRECISION` for the line that the server renders, and
  `DISPLAY_PRECISION` in `location_map_controller.js` for the line that a pin drop writes. The two
  must be equal, or a pin drop changes the format of the numbers where the user can see it. This
  does not change what the code stores: the controller saves at its own `PRECISION`, and the
  override callout prints the value of the environment variable word for word, on purpose.
- ⚠️ **`Location` uses `ENV["LOCATION"]` in place of the stored value.** Thus, with that variable
  set, a pin drop writes to Redis and changes nothing that a widget reads. The page renders a
  callout with the coordinates that win, and it does not appear to operate.
- ⚠️ **The token of the map is `MAPBOX_ACCESS_TOKEN`, and no other one.** The page contains that
  token, and the preference of `StaticMap` for `MAPBOX_SECRET_TOKEN` is exactly the fallback that
  must not occur here, because that token has `tilesets:write`. A request spec asserts that it is
  never in the body. With no public token, a callout replaces the map. The address box, the race
  shortcuts, and Save continue to operate, and geolocation does not, because its button is part of
  the map.
- **Geolocation is the `GeolocateControl` of Mapbox**, on the map beside the zoom control, and it is
  not a button of ours. It moves to the reading, it draws the accuracy circle, and it disables
  itself where the browser cannot geolocate. A button of ours could find that only after a press.
  Its `geolocate` event saves through the same path as a pin drop. ⚠️ **Never use
  `trackUserLocation`.** In active lock it fires again at each position update, and each one here is
  a write to Redis and a `LocationSyncJob`. Thus a phone that stays on this page syncs itself to
  Intervals.icu at each small GPS change.
- **Mapbox GL JS comes from the CDN of Mapbox, and the Stimulus controller loads it.** It does not
  come from npm. It is some times larger than the full admin bundle, one page needs it, and the map
  cannot operate without `api.mapbox.com`. Thus this adds no dependency that the page did not have.
  ⚠️ The controller loads it, and a `<head>` tag does not, because Turbo merges a new head and
  *adds* the elements. A deferred script arrives at an unknown moment, and the controller can
  connect before `mapboxgl` exists.
- ⚠️ **The code removes the map at `turbo:before-cache`.** Turbo makes the snapshot of the page
  before Stimulus disconnects. Without that step the cached copy contains the canvas of GL JS, and a
  restoration visit makes a second map above the dead one.
- The geocode of the heading is for display only and it degrades to nothing. Thus an unset
  `GOOGLE_API_KEY`, or a bad day at Google, leaves the coordinates and stores the location. ⚠️ **The
  address box is the exception**: `GoogleGeocoder` uses the *same* key, and without it the page
  refuses each address. That is the only control here with a hard dependency on another service, and
  the pin, the shortcuts, and Geolocation each have their own coordinates.
- **The race shortcuts are each confirmed race in the future**, from the same Contentful events that
  the upcoming-races widget reads, and the soonest one is first. ⚠️ This is not
  `EventsHelper#upcoming_races`, on purpose: that is the *selection* of the widget, with a maximum
  of three or four, and any race in the future is a place where you can be. The page drops a race
  with no coordinates in place of a button that cannot move the map. When Contentful is down, the
  page loses the shortcuts and nothing more.

### The course-map renderer

`/course-maps` makes a static PNG cover image for a race report from a GPX track. It is a front end
over the Data Workbench of Mapbox: upload one or more GPX files, wait while Mapbox publishes each
one as a private vector tileset, then open one to set its frame and its style and to download the
result.
(This replaced a `utilities/maps/` Rake task, which rendered each GPX in a folder with one shared
set of options from environment variables.)

There are four services, and none of them is a subclass of `ApplicationService`: `GpxTrack` parses
an upload, `TrackLibrary` is the Redis store, `MapboxTileset` speaks to the Mapbox Tiling Service,
and `StaticMap` makes the render URL and gets the image.

- ⚠️ **This code makes no composite image on the server.** The Static Images API draws the track,
  which is an `addlayer` over the tileset, and both pins, and it returns a complete PNG. Thus this
  page needs no image library and no system package, and it uses `nokogiri` and `httparty` only. Do
  not "improve" it into a local drawing: the 512MB VM ran out of memory in the past.
- ⚠️ **`GpxTrack` reads the file as a stream with `Nokogiri::XML::Reader`, and not as a DOM.** A
  true Garmin export is some megabytes and has approximately 9,000 points, and this parse operates
  in a Puma thread with a budget of 20 seconds for the request. The code rounds each coordinate to
  six decimals, which is approximately 11cm, at the input. Garmin writes 26 significant digits,
  which makes the Redis data and the Mapbox upload three times larger for no result.
- **There is one Redis hash**, `maps:tracks`, and each field name is the tileset id. The reason is
  the same as for the spam quarantine. A record holds the bounding box, both end points, the sport,
  and the render settings, because **the code discards the GPX after the upload**, and the settings
  page must still put the pins on a track from last week. `MAX_ENTRIES` is a guard against a runaway
  loop and it is not a retention rule: a track goes away only when the owner deletes it.
- ⚠️ **The coordinates go into their own key** (`maps:pending:<id>`, with a TTL of one hour), and
  not into the record and not into the arguments of the job. `app` and `worker` are different fly
  machines, thus a temporary file that the request writes is not there for the worker to read.
- ⚠️ **`MapTilesetJob` raises at a failure and does not record one.** Thus the 24-hour retry that it
  inherits applies, and `sidekiq_retries_exhausted` writes `status: "failed"`. To record the failure
  at the first exception makes the row change between failed, processing, and failed at each
  attempt. The job is idempotent, because an upload of the source replaces it and a tileset that
  exists counts as a success. That is what makes the retry safe, and the retry is necessary, because
  `kill_timeout` is 30s and a poll for the publish can continue for 300s.
- ⚠️ **`MapboxTileset#destroy!` deletes the tileset *and* its source.** To delete the tileset only
  leaves the source with no owner. That source still counts against the account, and the tileset
  list does not show it. The method raises for each result that is not a success and is not a 404,
  thus the code never deletes the local record while the remote one continues to exist.
- ⚠️ **`preview` and `download` proxy the render, and they never redirect.** The Static Images URL
  has `MAPBOX_SECRET_TOKEN` in a query parameter, thus an `<img>` that points at Mapbox gives the
  browser a credential with `tilesets:write`. Both render at `@2x`: the API bills for each request
  and not for each pixel, thus a smaller preview saves nothing. The zoom dialog also shows that same
  image at the full width, where 1x is one half of the pixels that a retina screen needs.
- ⚠️ **The style URL and the icons and the colors of the markers go into an outbound URL from form
  fields.** Thus `StaticMap` matches the style against the shape that Mapbox uses and removes each
  value that is not an icon id and not a hex color. For a bad style the code uses the default and
  does not put the value into the URL. The code also limits the number for each side, because those
  values come from number inputs.
- **The padding and the extra map are four settings each**, and not the shorthand string in the CSS
  style that the Rake task accepted (`PADDING=60,20`). The form shows one field while the four sides
  are equal, and four fields when they are not. `linked_sides_controller` copies the first value
  into the other three, and all four fields keep their name, thus the form always submits four
  values. The shorthand was short to type and very difficult to edit.
- **The map style is a dropdown and an override.** `style_preset` holds one of `STYLE_PRESETS`, and
  `style_url` holds a custom style and wins when it has a value. `MapTrackPresenter#settings` moves
  a preset that it finds in `style_url` back into the dropdown, and that is also how a record from
  before this split corrects itself.
- **The name of a marker icon says what it marks** (`MARKER_ICONS`), and it is not the Maki id. The
  first icon for a sport comes from `GpxTrack::SPORT_ICONS`, whose fallback is running and not a
  neutral icon.
- ⚠️ **Mapbox draws the last overlay on top**, thus the default order of the markers is
  `[finish, start]`, which puts the start on top. A finish pin above the start of an out-and-back
  course hides the start point. `finish_on_top` changes the order. The name of the setting says
  which state it makes. An earlier `reverse_markers` said how it operates, and its value read
  against its own label.
- ⚠️ **The preview stays below the sticky header with the `--header-height` of `<wa-page>`**, which
  the component declares but never measures. `_page.scss` sets it, `_admin-header.scss` takes the
  height of the bar from it, and `_track.scss` moves the sticky preview by it. To set it also
  corrects the `--scroll-margin-top` of the component for an anchor target.
- ⚠️ **This is the only admin page that needs the Sidekiq worker.** A track stays at "Processing"
  until `MapTilesetJob` publishes it. That is the reason that `worker` is no longer optional in
  `.overmind.env`. The index reads the process set of Sidekiq **only while a track is publishing**,
  and it says so when that set is empty. Without that message a row that is stuck looks the same as
  a row that is slow, and no page gives the reason. In production an empty set means that the worker
  machine is down.
- **The page polls, and the server does not push.** `map_status_controller` reads
  `/course-maps/status` again each 5s while a row is publishing, and it stops at each other moment.
  The engine of Action Cable is commented out in `application.rb`, and there is no `turbo-rails`.
  Thus a websocket is much new infrastructure for one user who is signed in.
- **`map_preview_controller` changes the `src` of the image and does not submit the form.** A submit
  is a Turbo visit, which replaces the body. Thus the field in use loses the focus at each keystroke,
  and a slider stops during a drag. The form is still a true GET form, thus the Enter key, and a
  browser with no JavaScript, both continue to operate. Each new render is one billed Static Images
  request, and that is the reason for the debounce.
- These are the **first form inputs** of the admin, and each other form here has an action only. The
  controls of Web Awesome are part of their form, thus they submit and appear in `FormData` as a
  native control does. The switch for the marker order has a hidden `0` field with it, because a
  switch that is off submits nothing.

`Admin::BaseController` needs the session of the owner. That controller, `SessionsController`, and
`WhoopOauthController` each include the **`OwnerFacing`** concern, which sets `Cache-Control:
no-store`, `X-Robots-Tag: noindex, nofollow`, and the **CSP** below. ⚠️ An admin action must never
call `cache_widget`. ⚠️ The `X-Robots-Tag` does more than the `<meta name="robots">` of the layout:
`public/robots.txt` refuses the full host, thus a crawler never gets the page and never *sees* that
meta tag, and a link from another site can still put the URL in an index.
⚠️ `WhoopOauthController` is in that list for the `no-store` specifically. Its callback carries the
OAuth `code` and `state` in the query string, and it renders no admin layout that can give that
signal.

**The Content-Security-Policy** is in `OwnerFacing`, thus it goes on those three controllers and on
no other one. ⚠️ `config/initializers/content_security_policy.rb` sets the nonce generator and
`nonce_directives` **only**, and it declares **no default policy**, on purpose. A default policy
puts the header on each widget fragment, and a fragment is not a document and the edge cache stores
its response. `spec/support/live_update_contract.rb` fails if a fragment gets such a header.

- The header is **Report-Only** unless `CSP_ENFORCE` has a value. Thus a source that a person forgot
  gives a report in the console and not an empty admin page, and to change that is a fly secret and
  not a deploy.
- ⚠️ The nonce applies to `script-src` **only**. A nonce in a directive makes a browser ignore
  `unsafe-inline` in that same directive, and `style-src` needs `unsafe-inline` for the styles that
  Web Awesome and Mapbox GL JS write at run time. To add `style-src` to `nonce_directives` again
  breaks each component, with no message.
- The inline dark-mode script in `layouts/_head.html.erb` has that nonce. It must stay inline and
  must run before the paint, thus the nonce is what keeps it in operation.
- `MAPBOX_ORIGINS` is for the location picker: GL JS and its stylesheet come from `api.mapbox.com`
  at run time, and the map then speaks to the tile hosts and the telemetry hosts directly. GL JS
  also runs its renderer in a Worker from a blob URL, and that is the reason for
  `worker-src blob:`.
- ⚠️ `Sidekiq::Web` renders its own layout with its own `csp_nonce`, and this policy does not cover
  it.

### Caching

The code is in `app/controllers/concerns/live_widget.rb`. `cache_widget(ttl:)` sets:

- For the browser: `Cache-Control: public, max-age=0, stale-while-revalidate=<ttl>`
- For the edge:
  `CDN-Cache-Control: public, max-age=<ttl>, stale-while-revalidate=3600, stale-if-error=86400`

⚠️ **Keep the edge `stale-while-revalidate` at its one-hour default.** A copy lives for its
`max-age` plus that window. Thus a longer window keeps an old fragment in some PoPs for that full
time, and a tag purge that misses gives no message.

This is RFC 9213: Cloudflare obeys `CDN-Cache-Control` and a browser ignores it. That is what
permits an edge TTL that is different from the `max-age=0` of the browser.

⚠️ **Never write the edge policy as `s-maxage`.** Its presence stops `stale-while-revalidate` and
`stale-if-error` (RFC 9111 §4.2.4), and those two keep each widget in operation through an outage
at fly.

⚠️ **Send these headers on a successful and cacheable response only.** The edge must never keep an
error.

⚠️ **A change to a `cache_widget(ttl:)` does not reach a copy that is already at the edge. Purge, or
the change does not arrive.** A cached fragment keeps the `CDN-Cache-Control` that it had at the
moment of the *store*. Thus each PoP serves the old body below the old policy until that policy
expires. One change of the pageviews TTL from 1 h to 5 min left copies below the earlier
`stale-while-revalidate=86400`. Thus a view count was as much as **25 hours** old, and it read as a
counter that goes down. A change to the markup has the same result.

**The purge is the one part of this policy that the app does not write.** A **zone Cache Response
Rule** puts `Cache-Tag: site` on each widget that renders Contentful content, and it matches
`/widgets/articles/*` and `/widgets/events/*` on this host. Thus the tag purge of the web deploy
removes them when a person publishes the content again. No code here and no code in the web proxy
sets that tag. ⚠️ **To move a widget out of those namespaces, or to add a Contentful-backed widget
below a new namespace, stops the purge with no message**, and no change to the code can correct it:
it needs an edit in the dashboard. The full reason, and the manual `widgets` tag, are in the root
[`CLAUDE.md`](../CLAUDE.md).

### Errors and abuse mitigation

- **Bugsnag** (`config/initializers/bugsnag.rb`) — its railtie adds the Rack middleware by itself
  and connects to ActionDispatch. Thus it reports each exception that no code catches, and the app
  still renders an error as plain text. `notify_release_stages` names production only, and
  `BUGSNAG_API_KEY` has no value on your machine and in CI. Thus Bugsnag does nothing outside
  production.
- **An error renders as plain text**, through `lib/plain_text_exceptions.rb`. A path with no route
  goes to the `match "*unmatched"` route at the end and then to
  `ApplicationController#route_not_found`. Thus a probe from a scanner gives one clean
  `status=404` lograge line and not a backtrace. ⚠️ That catch-all **must stay the last route**, and
  `spec/routing/routes_guard_spec.rb` checks that.
- **rack-attack** (`config/initializers/rack_attack.rb`) blocks each probe path with a flat 403 by
  **path pattern**, before the routing, and it throttles a request **to a path outside the known
  route prefixes**. The key is `Request#client_ip`, which is `CF-Connecting-IP`, then
  `Fly-Client-IP`, then `req.ip`.
  ⚠️ **The blocklist must not use an IP. Never ban by IP.** Some probe paths are available through
  the public `/widgets/*` proxy, and each correct widget request shares the egress IPs of that
  proxy. Thus a ban by IP gives a 403 to the widgets of each visitor at the same moment, and that
  made the site fail one time. For the same reason, use no throttle for each IP.
  ⚠️ **When you add a top-level route, add its prefix to `RACK_ATTACK_KNOWN_PREFIXES`**, or the code
  limits its rate. A prefix that is not there fails `spec/routing/routes_guard_spec.rb`.
  There is also a `contact/ip` throttle with a small scope (5 each hour). That is the one place
  where an IP for each visitor is safe: it uses the `X-Kona-Client-IP` that the proxy forwards,
  which is the true visitor and not the shared egress, and it is a throttle and never a ban. There
  is also a `signin/ip` throttle (30 each 5 min) over `/signin` and `/auth/`. ⚠️ Those two prefixes
  are in `RACK_ATTACK_KNOWN_PREFIXES`, and that is exactly what removes them from the
  `unknown-paths` throttle. Thus, without a rule of their own, the login pages had no limit at the
  origin. To use `client_ip` is safe *there*, because those paths are on the admin host, which no
  request reaches through the shared egress of the widget proxy.
- **The session of the owner** is the cookie store of Rails, and
  `config/initializers/session_store.rb` declares it to add `expire_after` only. ⚠️ A cookie session
  has no record on the server, thus there is nothing to revoke. Except for a new `secret_key_base`,
  a stolen cookie stays valid until the browser removes it. The expiry is the maximum.
- **Redis** — the global `$redis` comes from `config/initializers/redis.rb` and from `REDIS_URL`.
  The same Redis holds the Sidekiq queues.

## Commands

Run `nvm use` before each `npm` command, as you do in `web/`. There is one native dependency:
**libvips** (`brew install vips`), which `ruby-vips` opens at the boot of Rails. Thus `rspec` and
`bin/dev` both fail without it, and `web/` needs the same library.

```bash
bin/dev                                                          # the server here (or bin/setup)
npm run build                                                    # the admin bundle, one time
npm run watch                                                    # …or a new build at each change (the `js` overmind process)
bundle exec sidekiq -C config/sidekiq.yml                        # the worker here
bundle exec rspec spec/requests/widgets/activity_stats_spec.rb   # one spec
bundle exec rspec                                                # each spec
bin/ci                                                           # setup, the specs, the style, and the security
bundle exec rubocop                                              # add -a to correct each offense
bundle exec brakeman -q --no-pager
bundle exec bundle-audit check --update

# ⚠️ --build-secret is necessary: --remote-only makes the build on the builder of fly. Thus the
# token for the private registry must go with the build, or `npm ci` gets a 401 and the deploy fails.
fly deploy --build-secret WEBAWESOME_NPM_TOKEN="$WEBAWESOME_NPM_TOKEN"   # the app and the worker
fly console

# Start a new build of web. It needs a worker in operation. ⚠️ Against production this makes a true deploy.
curl -i -X POST -H "Authorization: Bearer $API_TOKEN" "$KONA_API_URL/api/build"
```

**RuboCop** uses `rubocop-rails-omakase`, which is the ruleset of Rails. `.rubocop.yml` inherits it
word for word and changes no rule. It turns on 50 of the 609 cops of RuboCop, and most of them are
Layout cops. There are no Metrics cops, thus no cop limits the length of a method or of a class.
⚠️ **Change no rule.** To take the omakase configuration *is* the decision to have no house style.
Turn a rule off in the code at the one place that needs that, and do not edit the configuration.
`web/` uses the same ruleset.

CI runs RuboCop, Brakeman, and bundler-audit, and the deploy job **operates only if all three
pass**. When Brakeman reports a problem that you checked and that is not true, add a
`config/brakeman.ignore` file to the repository and do not make the code weaker.

## Testing

The RSpec request specs are in `spec/requests/`, and there are also `spec/services/` and
`spec/presenters/`. There is no database and there are no fixtures. Stub a service with
`allow_any_instance_of(SomeService).to receive(:method).and_return(...)`. A spec asserts the markup
that the app rendered **and** the cache headers.

## Environment variables

This section gives the names only. Read `.env.example`, and never commit a value. Each production
value is a secret of fly.io, and Rails also uses `config/credentials.yml.enc` and `master.key`.

- **A credential for the build**: `WEBAWESOME_NPM_TOKEN` is the npm authorization for Web Awesome
  Pro, which the admin UI needs. `.npmrc` reads it at the install. It is not in `.env` and it is not
  a secret of fly, because the *build* needs it. Thus it goes to fly with `--build-secret`.

- **Required**: `REDIS_URL`, `ICU_ATHLETE_ID`, `ICU_API_KEY`, `FONT_AWESOME_API_TOKEN`,
  `WHOOP_CLIENT_ID`, `WHOOP_CLIENT_SECRET`, `WHOOP_REDIRECT_URI`, `GOOGLE_OAUTH_CLIENT_ID`,
  `GOOGLE_OAUTH_CLIENT_SECRET`, `OWNER_EMAIL`, `GOOGLE_API_KEY`, `API_TOKEN` (it must be equal to
  the token of the web app), `WEATHERKIT_KEY_ID`, `WEATHERKIT_TEAM_ID`, `WEATHERKIT_SERVICE_ID`,
  `WEATHERKIT_PRIVATE_KEY` (a .p8 file in base64), `CONTENTFUL_SPACE`, `CONTENTFUL_TOKEN`,
  `CONTENTFUL_WEBHOOK_SECRET` (an HMAC secret of 64 characters), `SITE_URL`, `IMAGES_URL` and
  `IMAGE_HOST` (the same values as the web app; with either one absent, the trending card renders no
  image), `RESEND_API_KEY`,
  `CONTACT_FROM_ADDRESS` (a sender on a domain that Resend verified — it needs SPF and DKIM only,
  thus it can share a domain with a Google Workspace mailbox), `CONTACT_TO_ADDRESS`.
- **Optional**: `AKISMET_API_KEY` (with no value the check is off and each message goes out with no
  check; with a value the check fails closed), `TURNSTILE_SECRET` (use it with the
  `TURNSTILE_SITE_KEY` of the web app; set both or set neither),
  `CSP_ENFORCE` (any value enforces the CSP for the owner; with no value the CSP is Report-Only),
  `FONT_AWESOME_VERSION`, `WHOOP_REFERRAL_URL`, `TRAINERROAD_CALENDAR_URL`, `ANTHROPIC_API_KEY` with
  `ANTHROPIC_DESCRIPTION_MODEL` and `ANTHROPIC_CONTACT_SUBJECT_MODEL` (the default of both is
  `claude-sonnet-5`), `PURPLEAIR_API_KEY`, `GOODSPEED_API_URL` (with no value the bay-conditions
  integration is off, and the app omits the sentence about the water temperature and the bay
  readings for a race day in SF), `LOCATION`, `TIME_ZONE`, `BLUESKY_PDS_URL` (⚠️ the handle and the
  app password of Bluesky are **not** environment variables: a person sets them on the Connected
  apps page of the admin, and the app stores them in Redis), `BUGSNAG_API_KEY` (for production
  only), `ALLOWED_HOSTS` (a list of permitted `Host` values, separated by a comma; for production
  only. With no value the app accepts each host, thus it is safe to deploy before you set it, and
  `/up` is always exempt), `API_HOST` (the public API host name. With no value the app draws each
  route on each host, thus this changes nothing in dev and in CI. ⚠️ Move `WHOOP_REDIRECT_URI` to
  the admin host before you set it), `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
  and `R2_BUCKET` (⚠️ this must be the bucket behind the `IMAGE_HOST` of the web app. No code checks
  that, and a difference gives a 404 for each image), `GITHUB_DISPATCH_TOKEN` and
  `GITHUB_REPOSITORY` (a fine-grained PAT with **Contents: Read and write**, and the `owner/repo`
  slug), `PLAUSIBLE_API_KEY` and `PLAUSIBLE_SITE_ID` (⚠️ if one of the two has no value, the
  pageviews widget collapses and `TrendingArticles` changes to the order by popularity with no
  message. An INFO log is the only sign, and the result looks exactly like "it operates, and nothing
  is trending"), `VOYAGE_API_KEY` (with no value there are no embeddings, thus `GET /api/related`
  returns `{}` and the build omits each "You May Also Like" section), `MAPBOX_USERNAME` and
  `MAPBOX_SECRET_TOKEN` (a token with `tilesets:write` and `tilesets:read`. If one of the two has no
  value, the Maps page says so and refuses each upload), `MAPBOX_ACCESS_TOKEN` (the ⚠️ **public**
  token: the server uses it to render when there is no secret token, and the map in the browser on
  the Location page needs it. With no value that page changes to a form for the coordinates),
  `MAPBOX_STYLE_URL` (the default style for a new track. Each track can use a different style, and
  the Location page ignores this value), `REDIS_POOL_SIZE` (the default is 10. Make it as large as
  the largest consumer, which is the concurrency of Sidekiq), the six `TRENDING_*` values for the
  trending ranking (read `.env.example`. They are part of the cache key of that ranking, thus a
  change to one makes the cache invalid), and the three `RELATED_*` values for the "You May Also
  Like" ranking (no cache holds that ranking, thus a change applies at the next build).

## Conventions & gates

- **Before a commit and before a deploy** (this rule has no exception): `bundle exec rspec` passes.
- Keep the markup of a widget the same as the markup of its `web/` placeholder (root `CLAUDE.md`).
- The app gets a Font Awesome icon on demand by its family, its style, and its id, and it caches the
  icon in Redis for each version: `icon_svg('classic', 'solid', 'eye')`. There is no allowlist here,
  and the app gets each id that a view names. The integration is in this app **only**: `web/` sends
  its own allowlist to `POST /api/icons`, thus a new icon in web needs no change in the api.
  ⚠️ That endpoint asks for the icons in small groups, thus a cold cache cannot go past the
  `rack-timeout` of the request. Do not change it to resolve the full allowlist in one request.

### Permissions

- Permitted with no question: read a file, run `rspec` on one file, and run `bin/dev` on this
  machine.
- Ask first: `fly deploy`, a change to a secret, each command that flushes Redis, `git push`, a
  commit, and the installation of a package.
