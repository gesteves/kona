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
| GET | `/api/related` | `{contentful id => [related ids]}` from the BM25 index of the article text, for the build's static "You May Also Like" section | — |
| POST | `/webhooks/contentful` | enqueues PDS sync, asset-mirror, and site-build jobs; 204 | — |
| POST | `/webhooks/whoop` | enqueues `WhoopWebhookJob`; 200 `{ok: true}` | — |
| GET | `/whoop/auth`, `/whoop/callback` | Whoop OAuth (authorize is owner-gated) | — |
| GET | `/signin`, `/auth/google_oauth2/callback`; POST `/signout` | owner session | `no-store` |
| GET | `/`, `/spam`, `/location`, `/connected-apps`, `/course-maps`, `/course-maps/:id` | admin UI (owner-session gated) | `no-store` |
| GET | `/social` | the Social media page | `no-store` |
| POST | `/social` | checks the draft and adds the FIRST post job of each network that the owner ticked, now or at a date and a time; 303, or 422 with the draft still in the form | `no-store` |
| GET | `/social/preview` | the card of a link, as JSON, for the preview on the page | `no-store` |
| POST | `/social/preview/text` | the draft as each connected network will receive it, as JSON, for the Preview dialog. ⚠️ A POST, because a draft is much larger than a query string should carry | `no-store` |
| GET | `/social/preview/image` | proxies the picture of that card. ⚠️ The parameter is the **page**, not the picture | `no-store` |
| POST | `/spam/:id/not-spam`; DELETE `/spam/:id`, `/connected-apps/whoop` | release or delete a quarantined message; disconnect Whoop | `no-store` |
| GET/POST/DELETE | `/connected-apps/bluesky` | the Bluesky handle + app password form, and disconnect | `no-store` |
| GET/POST/DELETE | `/connected-apps/mastodon`; GET `/connected-apps/mastodon/callback` | the Mastodon instance form, the OAuth callback, and disconnect | `no-store` |
| GET | `/connected-apps/threads/authorize`, `/connected-apps/threads/callback`; DELETE `/connected-apps/threads` | Threads OAuth, and disconnect | `no-store` |
| GET/POST/DELETE | `/connected-apps/trainerroad` | the TrainerRoad calendar-URL form, and disconnect | `no-store` |
| GET | `/location/lookup` | resolves an `address` or a coordinate pair to `{latitude, longitude, place}`. ⚠️ **Never writes** | `no-store` |
| POST | `/location` | same write as `POST /api/location`, coordinates only; answers with the coordinates and the geocoded place | `no-store` |
| POST | `/republish` | starts a build of the web site after the minutes that the owner picks, where zero is now. The Republish dialog of the nav posts here with fetch, and the answer is JSON | `no-store` |
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
Goodspeed, Akismet, Resend, Turnstile, Mastodon (OAuth2), Threads (OAuth2), `StandardSite`, `Bluesky`,
`OpenGraph`,
`AssetMirror`, and `BlurhashPlaceholder`.
The two article rankings, `TrendingArticles` and `RelatedArticles`, share `ArticleRanking`. Three
more classes hold the parts of the "You May Also Like" score: `ArticleIndex` is the BM25 index of
the article text, `ArticleTaxonomy` is the concept overlap, and `RelatedInspector` makes the two
reports of `rake related:*`. Refer to **The article rankings**.
Eight more are not subclasses of `ApplicationService`, because they are not cacheable reads:
`SpamQuarantine`, `TrackLibrary`, `BlueskyCredentials`, `MastodonCredentials`,
`ThreadsCredentials`, and `TrainerRoadCredentials` use Redis only and no HTTP; `GpxTrack` parses
only; and `MapboxTileset` and `StaticMap` are different (refer to **The
course-map renderer**). The four credential stores share the `EncryptedCredentials` concern,
which encrypts each secret field, and `WhoopCredentials` gives the Whoop tokens, which keep their
own keys with a TTL, the same encryption. ⚠️ **Never change the `ENCRYPTION_SALT` of a store**: the salt is
part of the key, thus a new salt makes each stored secret unreadable and each card says "not
connected".
`ApplicationService#download` reads a URL in fragments and stops at a byte limit. ⚠️ Use it for
each body whose size another site decides, for example an `og:image`: the worker is a 512MB VM.
It also refuses a URL that is not public, and it checks each redirect hop (`PublicAddress`): a page
that another site names can send the app to the private network of fly.
`cached_json(key, expires_in:)` gives the read-through Redis cache. HTTParty makes each request, and
it tries again after a failure. `DeepOstruct` gives dot access.

⚠️ **Plausible permits 600 calls each hour**, and `cached_json` limits each different query body to
one call for its 5-minute TTL. Thus the number of *different queries* is important, and the number of
requests is not. For that reason each `Plausible` aggregate is **one query for the full site**, and
never one query for each article. A query for each article would make one key for each article, and
the number of calls would then grow with the number of articles and go past the limit. **Do not add
a query for each article, and do the calculation again before you make either TTL shorter.**

There are **five different query bodies**, which is 60 calls each hour:

| Method | Dimension | Metrics | Who reads it |
|---|---|---|---|
| `totals_by_path(date_range: "all")` | `event:page` | `visitors`, `pageviews` | the pageviews widget reads the pageviews; `TrendingArticles` and `RelatedArticles` read the visitors |
| `page_visitors_by_path` (the recent window) | `event:page` | `visitors`, `pageviews` | `TrendingArticles` |
| `page_visitors_by_path` (the baseline window) | `event:page` | `visitors`, `pageviews` | `TrendingArticles` |
| `entry_visitors_by_path` (the recent window) | `visit:entry_page` | `visitors` | `TrendingArticles` |
| `entry_visitors_by_path` (the baseline window) | `visit:entry_page` | `visitors` | `TrendingArticles` |

⚠️ **`TrendingArticles` blends the two dimensions, and it never reads the pageviews.** A reader who
arrives on the home page and then selects one article is a true signal, and `visit:entry_page` alone
cannot see it. But the trending widget renders on the home page and on each Page, thus its own
clicks are part of `event:page`, and a rank on that dimension alone puts the output of the module
back into its own input. At the traffic of this site that loop can supply most of the recent traffic
of an article.

The blend keeps both properties: `visit:entry_page` is the demand from **outside** the site and gets
the full weight, and the difference between the two dimensions is the arrivals from **inside** the
site and gets `TRENDING_INTERNAL_WEIGHT` (default 0.5). Refer to `TrendingArticles#heat_by_path`.

⚠️ **Keep that weight below 1**, and keep the metric at `visitors` and not `pageviews`. The visitors
metric counts a reader one time however many times they load the page, thus a reload cannot raise
it.

⚠️ **The recent window and the baseline must use the same blend.** The score is a ratio of the two,
and a different blend on each side gives a number with no meaning. ⚠️ `heat_by_path` returns an
empty hash when **either** query is not available. A blend of one good query and one empty query
would score each article on its internal traffic alone, and that list looks correct.

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

- **`config/srcsets.yml`** holds the shape (`ratio`), the `sizes`, and the candidate
  widths of the card. It is a copy of
  `web/data/srcsets.yml`, word for word, and `ImagesHelper` reads its `card` variant one time at
  boot. ⚠️ Copy the full file (`cp web/data/srcsets.yml api/config/srcsets.yml`), and do not copy
  the `card` block alone: `spec/contracts/srcsets_contract_spec.rb` compares the two files and
  fails on each difference. That file also gives the method that makes the widths.
  ⚠️ The file has a second card variant, `card_large`, which the static site alone renders. This
  app reads `card` and never sees it. ⚠️ `card_large` uses a YAML **merge key**, thus each
  `YAML.load_file` of this file needs `aliases: true`. The constant below reads the file at boot,
  and Psych 5 refuses an alias by default. Without the flag the app raises at boot.
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

**`TrendingArticles`** reads the blended visitors of two moving windows and gives each article a
score. Read the ⚠️ above about the blend of `visit:entry_page` and `event:page`.

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

**`RelatedArticles`** makes a BM25 index of the text of each article and gives each candidate a
score. It calls no external API: the text comes from `Articles#corpus`, which is the same Contentful
read that each other list uses.

- ⚠️ **Do not change this into a neural embedding.** This corpus is approximately 60 entries by one
  author in one domain. An embedding of it puts most of its magnitude into the one direction that
  each entry shares: a measurement gave a mean similarity of a pair of **+0.48**. The scores then
  group into a narrow band where the order is near to noise, and the code needs a correction to
  operate at all. The IDF of BM25 removes that shared vocabulary by design.
- ⚠️ **A person can read the words that two articles share.** No A/B test can operate at this
  traffic, thus a person must read the order and judge it. `terms_in_common` gives those words, and
  `rake related:inspect` prints them. That is not possible with a vector, and it is a large part of
  the reason for this design.
- ⚠️ **The BM25 length normalization is necessary and not a refinement.** The median Article is
  approximately 18,000 characters and the median Short is approximately 1,000. At `B = 0`, each long
  article would win against each Short at every query.
- ⚠️ **The index reads the published entries alone.** A draft in it would change the IDF of each term
  and the mean document length, thus it would move a score that no person can explain.
- ⚠️ **There is no stop word list, on purpose.** The IDF gives a term that most of the corpus holds a
  weight near zero. A list would remove almost nothing, and it would add a file to maintain.
- ⚠️ **The concept overlap uses an IDF weight.** "Race Reports" is on most articles and gives almost
  no information, and "Ironman Canada" is very specific. A plain Jaccard would let the common
  concepts control the result, and each article would look related to each other article.
- ⚠️ **The floor reads the relevance and not the score.** The score holds the small addition for the
  date and the popularity. A new or a popular article that is not related must never go past the
  floor because of that addition.
- ⚠️ **`MIN_SCORE` must stay above zero.** A BM25 similarity and a concept overlap are both never
  negative, thus a floor at zero would mark each candidate as related. `LEXICAL_WEIGHT` moves that
  distribution, thus read `rake related:inspect` after a change to it.
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
ranking helped. `inspect` prints each candidate with its BM25 similarity, its concept overlap, its
score, and **the words that the two articles share**. `audit` gives the coverage of the index, the
number of entries with a short list, and the spread of the similarity of a pair.

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
| `SiteBuildJob(event_type)` | fires a GitHub `repository_dispatch` to rebuild the web site. ⚠️ The one job that a caller schedules, with `perform_at` |
| `WhoopWebhookJob(event_type, resource_id, trace_id)` | syncs Whoop metrics to Intervals.icu |
| `ActivityDescriptionJob(activity_id, whoop_strain = nil)` | (re)generates an activity's Strava description and tidies its name |
| `LocationSyncJob(latitude, longitude)` | propagates the current location to Intervals.icu |
| `BlueskyPostJob(posts, index, reply)` | posts one post of a thread to Bluesky, then adds the job of the next |
| `MastodonPostJob(posts, index, in_reply_to_id)` | the same, for Mastodon |
| `ThreadsPostJob(posts, index, reply_to_id)` | the same, for Threads |
| `ContactMailJob(name, email, message, context, restored_from_spam = false)` | contact intake: Akismet + compose |
| `ContactDeliveryJob(payload)` | the one retryable *delivery* unit — sends via Resend |
| `MapTilesetJob(id)` | publishes an uploaded GPX track to Mapbox as a vector tileset |
| `WhoopTokenRefreshJob()` | forces a Whoop token refresh on a schedule (see below) |
| `ThreadsTokenRefreshJob()` | renews the 60-day Threads token each day (see below) |

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
  - **This is the one job that a caller schedules.** `.schedule_in` uses `perform_in`, which puts
    the job in the scheduled set of Sidekiq, and the Scheduled tab of `/sidekiq` lists it.
    ⚠️ **The admin keeps one scheduled republish only.** `.schedule_in` keeps its jid in
    `SCHEDULED_JID_KEY`, and it calls `.cancel_scheduled` first. Thus a second republish replaces
    the first, and it does not add a build. An immediate republish cancels it as well, **after** it
    takes the trigger lock: in the other order, a click inside the window of that lock would cancel
    the scheduled build and start nothing. The jid can name a job that ran already, or one that a
    person deleted in `/sidekiq`; `find_job` gives nil for both, and the code then cancels nothing.
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
`/sidekiq` dashboard, which the owner session controls. Today there are two scheduled jobs.
`ThreadsTokenRefreshJob` runs each day, and it is the thing that keeps the Threads connection: that
token lives 60 days, it has no refresh token, and an expired one is dead for all time. Refer to
**Connected apps**. `WhoopTokenRefreshJob` runs each 6 hours. Whoop rotates its refresh token at each refresh, and it makes
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

⚠️ A presenter of the **admin** has no view context, thus it calls `I18n.t` and not the bare `t`.
Refer to **The admin UI** for the rule that puts each admin word in `config/locales/en.yml`.

### The admin UI

An admin UI for the owner, with **Web Awesome Pro** components. It is the one part of this app with
an asset pipeline, a layout, and JavaScript in the browser. Each other part still renders a
`layout false` fragment.

⚠️ **Each user-facing word of the admin is in `config/locales/en.yml`, below `en.admin.*`.**
A view uses the lazy key of its own path (`t(".title")` in `admin/spam/index.html.erb` reads
`en.admin.spam.index.title`), and a file below `app/views/layouts/` uses the full key, because it
renders from more than one page. A presenter, a controller, and a helper use the full key, and a
presenter calls `I18n.t` and not the bare `t`. **Write no user-facing word in an ERB file, in a Ruby
method, or in a JS file.**

- ⚠️ **This is for ONE place for the copy, and not for a second language.** A spec asserts
  `I18n.t("admin.…")` and never the words, thus a change to a word breaks no spec. That is the
  purpose. `spec/support/translation_helpers.rb` has `t_before`, for a message where an
  interpolated value — a date, a count — is the thing that the spec must prove.
- ⚠️ **Only the WORDS move.** An icon id, a path, a CSS class, a `data-` hook, a DOM id, and a Web
  Awesome `variant` stay in the code. `ConnectedAppPresenter#status_variant` stays beside
  `#status_label`, which left.
- ⚠️ **A DOM id must never come from a translated word.** The caption of a nav group takes its id
  from the `:key` of that group, and `aria-labelledby` points at it. An id from the label would
  move when a person changes a word.
- ⚠️ **Each key is a COMPLETE sentence.** Do not join one from a label and a fragment. Where a part
  is optional — a date, the "with the Bluesky handles" clause — there are **two keys** and the code
  selects one. `admin.social.errors.*` has a `single` form and a `numbered` form for that reason.
- **`config.i18n.raise_on_missing_translations` is on in development and in test**, thus a key with
  a spelling mistake fails a spec and never renders `translation missing:` on a live page.
- A sentence with an element in it uses an `_html` key and an interpolation, for example
  `t(".no_token_html", variable: tag.code("MAPBOX_ACCESS_TOKEN"))`. Rails escapes each value that
  goes into such a key.
- ⚠️ **The widget views and the widget presenters are NOT part of this rule.** `WeatherSummaryPresenter`,
  `WhoopPresenter`, `EventWeatherPresenter`, and `UpcomingRacesPresenter` render public-site copy,
  which is part of the markup contract with `web/` and which the edge caches. Leave it in the code.
- **The words that a Stimulus controller renders come from the same file.** JavaScript cannot read
  `en.yml`, thus `AdminHelper#admin_i18n_data(scope, **nested)` writes the subtree into a
  `data-admin-i18n` attribute and `app/javascript/lib/i18n.js` reads it, does the `one`/`other`
  choice, and puts each `%{name}` value in. ⚠️ It is a plain `data-` attribute and **not** a
  Stimulus value: a value arrives through a MutationObserver, thus it is not synchronous, and a
  controller reads this table at `connect()`.

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

**The messages.** ⚠️ **Each message that an action gives is a TOAST, and there is no flash callout.**
The layout renders the stack one time, as `<wa-toast id="notifications">`, outside `<wa-page>` for
the same reason as the dialog. Two things write into it, and the Rails `flash` continues to carry
the words of an action that redirects:

- **The server**, for a redirect. The layout renders one `<wa-toast-item>` for each flash entry, and
  `notice` gives `success` and `alert` gives `danger`. ⚠️ `<wa-toast>` starts the timer of each item
  that its slot receives, thus an item that the server renders shows itself and needs no code of
  ours. ⚠️ It carries `wa-cloak`, or the words show as plain text at the end of the page until
  `<wa-toast-item>` has a definition.
- **`app/javascript/lib/toast.js`**, for an action that fetches and leaves the page as it is. The
  Republish dialog is the one caller today.

⚠️ **The `toast` Stimulus controller empties the stack before Turbo caches the page.** The countdown
of an item stops when Turbo disconnects the DOM and never starts again, thus an item in a snapshot
appears again and does not go away. The dialog controller exists for the same problem.

⚠️ **Neither side sets a `duration`.** The default of `<wa-toast-item>` is the time on screen for
both, thus one value covers them.

⚠️ **A `<wa-callout>` that stays on a page is a different thing, and it is correct.** An empty state
(Spam, Course maps), a warning about the configuration (Location, Course maps), and the error of one
card or one row (Connected apps, a failed track) are all true at each load of that page. A toast goes
away after some seconds and never comes back, thus **do not change one of those into a toast**.

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

⚠️ **Three flows must refuse Turbo** with `data-turbo="false"`: the Google sign-in form, the
**Connect** link of Whoop, and the instance form of Mastodon. Each one is a same-origin URL that
redirects to a different origin, and Turbo Drive cannot follow that. It fails with no message, and
the click appears to do nothing. The Connected apps view puts the attribute on the Connect button of
each card. For a card whose path is an ordinary admin page, which is the form of Bluesky, the only
cost is a full page load.

The header has the wordmark of the site, `layouts/_logo.html.erb`, which is a **copy word for word**
of `web/source/partials/_logo.svg.erb`. ⚠️ Its paths contain `fill="#020a0a"`, which you cannot see
on the dark theme. `_admin-header.scss` changes that to `currentColor`, and that is also the reason
for the inline SVG in place of an image: an `<img>` cannot take the color of the text. A difference
between the two copies costs no more than an old admin logo.

The sidebar comes from `AdminHelper`: `#admin_nav_items` gives the two items with no group, which
are Home and Republish site, and `#admin_nav_groups` gives the groups with a caption, which are
Tools, Messages, Settings, and More. Both render through `layouts/_admin_nav_item`, thus the code for the
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
build of the web site, after 0 to 60 minutes. The rules of that dialog:

- ⚠️ **It is a sibling of `<wa-page>`, and not a child.** That component moves its
  `slot="navigation"` content between the sidebar and the drawer, and the dialog must not travel
  with it.
- ⚠️ **The two footer buttons are outside the `<form>`.** A slot takes a direct child of the dialog
  only. `form="republish-form"` joins the submit button to that form, because `<wa-button>` is
  form-associated and reads that attribute as a native control does.
- ⚠️ **The delay is minutes from now, and not a date and a time.** Thus the browser sends no time
  zone, and the server needs none: it adds the minutes to the current time. Do not add a date field
  again. ⚠️ **The Social media page *does* take a date and a time, and that is not a contradiction**: it
  sends the IANA zone of the browser in a hidden field. This dialog needs no zone at all, and a
  republish is never more than an hour away. Refer to **The Social media page**. `MIN_MINUTES` and `MAX_MINUTES` bound the delay, and 60 minutes also stops a job that would
  sit in Redis for a long time.
- ⚠️ **A delay of zero is "now", and the dialog has one control and no radio group.** The **label of
  the submit button** is the only thing that says which of the two the value gives: "Republish now"
  at zero, and "Republish in 5 minutes" above it. Thus `republish_controller.js` must keep that
  label with each edit of the field. A value outside the limits gets the plain word, and the
  `required`, `min`, and `max` of the field then stop the submit.
- ⚠️ **`RepublishController` matches the digits before it converts.** `to_i` gives 0 for text, and 0
  is now, thus `"soon"` would start a build. It reads `"5.9"` as 5. The number input of the dialog
  carries the same limits, but a client can send any value.
- **The field submits the form on Enter**, because the submit button is in a slot outside that form.
  The controller stops the default action first, thus one Enter gives one submit whether or not the
  browser finds the button through its `form` attribute.
- ⚠️ **The submit is a fetch, and the action answers with JSON and never a redirect.** The dialog
  closes and the page below it stays. That page can hold work that nothing saved — a draft of the
  Social media page is 300 characters and a link — and a navigation would take it away. Thus there
  is also **no flash**: the words go in a toast, which is the answer of that one request.
  `republish_controller.js` sends the CSRF token in a header, because the admin does not skip the
  forgery protection.

A group is only a caption above its own `<ul>` of those same links:

- ⚠️ **The caption is a `<div>`, and not a heading element.** It is above the `<h1>` of the page,
  thus a true heading would come before that `<h1>` in the outline of the document. The `<ul>` has
  an `aria-labelledby` that points at the caption, and that is what joins the two for a screen
  reader.
- ⚠️ **`_admin-nav.scss` makes the icon box of each item square**, against the `width: auto` that
  `_base.scss` gives to each inline SVG. The viewBox of a Font Awesome icon is not always square,
  thus at an automatic width no two labels in the column start at the same x.

**Connected apps** (`/connected-apps`) connects Whoop, Bluesky, Mastodon, Threads, and
TrainerRoad, and disconnects them.
`ConnectedAppPresenter` renders three states from `connected?` and an optional `error:` string. The
third state, `:error`, means connected but broken, and it gives **both** Reconnect and Disconnect. A
new authorization is the correction, and a rule to disconnect first would remove the one thing that
makes this state different from a new setup.

⚠️ **A card is on the page only when its integration can operate.** `#show` calls `valid_credentials?`
and leaves out the card of an integration whose credentials are absent from the environment, thus
there is no `:unconfigured` state and no card that offers no action. Today that applies to **Whoop**
and **Threads**. Bluesky, Mastodon, and TrainerRoad have no such configuration — their credentials
*are* the connection — thus their cards are always there and the page is never empty.

**A card that is connected names its account** — "Connected as …" — and a card that is not connected
says what the integration does. `#card_description` makes that one line for each of the five.
TrainerRoad names none: a calendar feed has no account, thus its connected card says "Connected."
⚠️ **Each of those names comes from Redis, and no card makes a request to get one.** That page
renders on each load of the admin, thus a fetch would put an upstream failure in the path of the
navigation. `StandardSite#connected?` has the same rule, and its comment gives the reason.

⚠️ **Each call to another service from a connect or a disconnect action has a timeout**
(`Mastodon::REQUEST_TIMEOUT`, `Threads::REQUEST_TIMEOUT`, and `AtProto::SESSION_TIMEOUT`). Those
actions run in a request with a 20-second rack-timeout, and that timeout raises an exception that
is **not** a `StandardError`, thus `rescue_with` does not catch it. Without the timeouts a host that
hangs gives a 500 in place of the message of the page, and a disconnect never reaches its clear.

- **Whoop** uses OAuth, and `Whoop#disconnect!` removes the tokens. ⚠️ It also deletes the cached
  `user_id`, because `Webhooks::WhoopController` authorizes each payload against it. A copy that
  stays continues to accept a webhook for an account with no tokens.
  - The card names the athlete with the email address that `store_account_email!` stores at the
    authorization. ⚠️ **`WhoopTokenRefreshJob` stores it when it is absent**, and that is the only
    thing that gives the label to a connection from before this code. Without it the owner must
    authorize again to see which account is connected.
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
    `secret_key_base`, through `EncryptedCredentials`. That password is a credential for the full
    account, it operates from any client, and this Redis also holds the Sidekiq queues. A failure
    to decrypt returns nil and does not raise, thus a new `RAILS_MASTER_KEY` gives "not connected"
    in place of an error on each page that shows the status.
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
- **Mastodon** does an OAuth round trip, and the Social media page posts to it. `Admin::MastodonController` has all four of its actions, and
  `MastodonCredentials` keeps the client and the token in the Redis hash `mastodon:credentials`. The
  client secret and the access token are encrypted, for the same reason as the Bluesky app password.
  - ⚠️ **Mastodon has no central developer dashboard, because each instance is a separate server.**
    Thus the owner names an instance, the app registers itself there (`POST /api/v1/apps`), and it
    keeps the client that the instance gives. **There is no environment variable and no dashboard
    step**, thus the page always shows this card.
  - ⚠️ **The `redirect_uri` comes from `mastodon_callback_url`, thus it names the host of the
    request.** The registration and the token exchange must send the same value, and for that reason
    the store keeps it. A client that a person registered from one host does not operate from
    another one, and the instance answers `invalid_grant`. To connect the account again corrects it.
  - ⚠️ **`store_client` removes the token and the handle.** Without that, an owner who names a
    second instance keeps the token of the first one, and the card shows "Connected" for an account
    that the new client cannot reach.
  - ⚠️ **`Mastodon#connect!` reads the account before it stores the token.** A token that cannot
    read its own account is not a connection, and the card must not show one.
  - ⚠️ **The callback is an admin page, thus the owner session controls it**, and the one-time state
    controls it a second time. The state is in the session (`OauthState`), thus only the browser
    that started the flow can complete it, and it goes away after a successful exchange only.
    Whoop, Mastodon, and Threads share that concern.
  - ⚠️ **The instance ties the scope to the token that it gives.** Thus a change to
    `Mastodon::SCOPES` needs a new registration and a new authorization, and the owner must connect
    the account again. `write:statuses` is what `Mastodon#post!` needs; refer to **Posting to
    Mastodon**.
  - **`disconnect!` tells the instance to revoke the token, then clears the store.** ⚠️ It clears
    the store whether the revoke works or not: the instance can be away, and a disconnect that the
    owner asked for must not depend on that. The clear is in an `ensure`, thus a rack-timeout
    cannot skip it, and the revoke has a timeout of its own.
- **Threads** does an OAuth round trip with Meta, and the Social media page posts to it. Its app
  credentials are `THREADS_APP_ID` and `THREADS_APP_SECRET`, from the Meta dashboard, thus this card
  *does* go off the page without them and the Mastodon card does not. `Admin::ThreadsController` has
  the three actions, and `ThreadsCredentials` keeps the token in the Redis hash
  `threads:credentials`, encrypted for the same reason as the Bluesky app password. There is **no form**: the app
  credentials come from the environment, thus the Connect button goes to the authorize action, as
  the one of Whoop does.
  - ⚠️ **A Threads token expires, and an expired one is dead for all time.** Meta gives a token of
    1 hour, which `connect!` changes into a token of 60 days, and there is **no refresh token**: the
    token renews itself. Thus `ThreadsTokenRefreshJob` is not an improvement, and it is the thing
    that keeps the connection. Without it the account disconnects itself 60 days after a person
    connects it, and only a new authorization corrects that.
  - ⚠️ **Meta refuses a refresh of a token that is less than 24 hours old.** `refresh!` gives
    `:too_soon` for that and never records a failure. Without that state, the card would say "Needs
    attention" for a connection that a person made minutes before.
  - ⚠️ **The `redirect_uri` is NOT an environment variable**, and `threads_callback_url` gives it
    from the request. Thus it always names the admin host, which is the only host that draws the
    callback route, and the ⚠️ that `WHOOP_REDIRECT_URI` needs does not apply here. **The Meta
    dashboard must list that same URL** in the redirect callback URLs of the app.
  - ⚠️ **`SCOPES` asks for each permission that the Meta dashboard permits**, but for
    `threads_trending_topics`, which the owner did not enable. **`threads_manage_replies` is the one
    that a THREAD needs**: the dashboard describes it as "create a reply on behalf of a Threads
    profile", and a container with a `reply_to_id` is a reply. Without it every reply container
    answered 500. ⚠️ **The dashboard must permit each scope in that list first.** Without that, the
    authorization screen fails and no code here can show the reason.
  - ⚠️ **The reply guidance of Meta is misleading.** It says a reply needs the **owner of the root
    post**, or `threads_keyword_search`, or `threads_manage_mentions`. This account **is** the owner
    of its own root post, thus by that rule it needs no permission and the reply still failed. Read
    the description of the permission in the dashboard, and not that page.
  - ⚠️ **Meta answers `500` with an EMPTY body for a scope that the token does not hold**, and not
    a 403 and not an OAuthException. Thus a missing scope reads as a fault of Meta. To name one,
    call `GET /{user}/threads_publishing_limit`: `fields=quota_usage` answers 200 with the scopes
    above, and `fields=reply_quota_usage` answers the same empty 500 when `threads_manage_replies`
    is absent.
  - ⚠️ **A new scope needs a new authorization by the owner.** A token that exists keeps the scopes
    that made it, thus the owner disconnects Threads on the Connected apps page and connects it
    again.
  - ⚠️ **`Threads#connect!` reads `/me` before it stores the token.** A token that cannot read its
    own account is not a connection, and the card must not show one.
  - ⚠️ **Meta gives no endpoint to revoke a token**, thus `disconnect!` is a local removal only. To
    end the access at Meta, the owner must also remove the app at Threads → Settings → Website
    permissions.
  - The card names the account. A refused refresh gives the `:error` state, exactly as a refused
    Whoop refresh does.
  - ⚠️ **An expired token stays in the store, thus `connected?` stays true.** `Threads#expired?`
    is the one thing that shows the difference: the card then gives the `:error` state with the
    date of the expiry, `refresh!` answers `:expired` and the job writes a warning, and the Social media
    page disables the row through `Threads#usable?`. Without those three, a dead token showed a
    green badge and a post job that retried for 24 hours.
  - ⚠️ **A token response with no `expires_in` gets `DEFAULT_TOKEN_LIFETIME`.** With `nil.to_i`
    the token expired at once, and `refresh!` then never touched it.
- **TrainerRoad** is a calendar feed and not an account: the iCalendar URL *is* the connection.
  Thus it connects with a form at `/connected-apps/trainerroad`, as Bluesky does, and
  `Admin::TrainerRoadController` has all three of its actions. `TrainerRoadCredentials` keeps the
  URL in the Redis hash `trainerroad:credentials`. ⚠️ **That page is the only method to set it, and
  there is no environment variable.** Thus the rest-day check and the 🗓️ planned-workout line do
  nothing in a new environment until a person connects the feed.
  - ⚠️ **The code encrypts the URL at rest**, through `EncryptedCredentials`, because a TrainerRoad
    iCal URL ends with a GUID that *is* the credential: it gives the full calendar to each person
    who has the URL. `TrainerRoad#calendar_version`, which is the digest that each cache key holds,
    exists for the same reason.
  - ⚠️ **`TrainerRoad#connect!` gets the feed and parses it before it stores the URL**, with
    `CONNECT_TIMEOUT`. A URL with a typing error, stored with no check, makes each rest-day check
    and each planned-workout line fail with no message.
  - The card names no account, because a feed has none, thus a connected card says "Connected."
    A request to read the name of the calendar would put an upstream failure in the path of the
    navigation, which is the rule above.

### The Social media page

**Social media** (`/social`) drafts a post, or a **thread** of them, for Bluesky, Mastodon, and
Threads, now or at a date and a time. All three post. Each post has an **optional** link.

- ⚠️ **The link is OPTIONAL, and every post has one of its own.** A post with none is words alone
  and it makes no card, and the job then reads no page at all. The action refuses a link only when
  it is **there** and it is not http or https.
- **The link is a plain `wa-input type="url"`, and there is NO list of the entries.** The owner
  pastes a link. ⚠️ **Do not add a picker of the articles back.** The card of a post comes from the
  `og:` tags of whatever page the link names, thus a link to another site needs no more code, and a
  list would cover this one site only. The action checks only that the value is http or https.
  - ⚠️ **The result is that this page makes NO request to Contentful when it renders**, and a spec
    pins that. An earlier version read `Articles#list` into a `wa-combobox` of every entry, and it
    also had to leave `ArticleRanking#candidates` alone, because that filter drops each Short.
- **The link has THREE states, and exactly one control of the three is on the page at a time.**
  `social_post_controller.js` holds them, and `_post.html.erb` renders the first one:

  | State | What shows below the toolbar | What moves it on |
  |---|---|---|
  | `IDLE` | Nothing; the **link button** of the toolbar is live | A click opens the field |
  | `EDITING` | The **link field**, with an X in it | A URL that the app can read a page for; the X and the Escape key go back to `IDLE` |
  | `ATTACHED` | The **card** of that link, with Edit and Remove in its footer | Edit goes back to `EDITING`; Remove goes back to `IDLE` |

  - ⚠️ **The toolbar is a ROW of controls and not one button.** A control for a photo, and each
    other kind of attachment, goes beside the link button. The **count sits at the end of that same
    line**, with `margin-inline-start: auto` and **not** `space-between`.
  - ⚠️ **The link button is DISABLED outside `IDLE`, and it is NEVER hidden.** It is a form control
    and it is taller than the count beside it, thus a button that goes away takes the height of the
    row with it and the count moves up at the click that opened the field. There is one link for
    each post, thus a live button in the other two states could do nothing anyway.
  - ⚠️ **The SERVER renders the state**, from `post.link`: a post with a link gets the field open
    and the button disabled, and a post with none gets a live button. Thus a page that renders
    again after a refusal shows the link that the owner wrote, and the controller moves nothing
    when it connects.
  - ⚠️ **EACH of the two later states needs its own way back to `IDLE`**, and all three controls
    call `removeLink`. Remove on the card cannot serve `EDITING`: a field that the owner opened and
    left empty never becomes a card, thus that field carries an X of its own and takes the Escape
    key.
  - ⚠️ **The field reads the page again when it loses the focus** (`commitLink`). Edit opens it with
    a URL already in it, thus a person who changes nothing fires no `input` and no `change`, and the
    card would never come back. `OpenGraph` caches for 15 minutes, thus that read is nearly always a
    Redis hit.
  - ⚠️ **Going back CLEARS the value, and it does not only close the field.** The field is the
    link, thus a field that closes with a value in it would still send that value with the form.
  - ⚠️ **`removeLink` sends an `input` event of its own.** A value that code writes fires none, and
    the form validates on `input`; without it the submit button would keep the state of a draft
    that the click emptied. That event also stops the timer, the spinner, and the request that is
    still out.
- **The page previews the card before the owner posts.** `GET /social/preview` gives the card as
  JSON, and the Stimulus controller reads it 600ms after the typing stops. A **`Standard.site`
  badge** on that card says that the post will get the enhanced card, and that is the thing the
  owner cannot know until after the post without it. ⚠️ **There is ONE badge, and no badge means
  the ordinary card from the og: tags.** A badge for each of the two states named the ordinary card
  on nearly every draft and said nothing.
  - ⚠️ **That card shows for EVERY link that this app read a page for, and it is not the card of
    Bluesky.** The field is hidden by then, thus this card is the only thing that says which link
    the post carries. A page with **no og: tags** still gets one, with its **address in place of a
    title**: a host name alone reads the same for two links to one site.
  - ⚠️ **The Preview panel is the opposite, on purpose**, and `#preview_card` sends it nothing for
    such a page: that panel shows what each network will RENDER, and Bluesky renders no embed. The
    link is in the words of the Bluesky row there. Both read `#card_json`, thus the two can never
    describe one page differently; only the decision to draw one differs.
  - ⚠️ **Edit and Remove go in the `footer` slot of the card, and NOT in `footer-actions`**, which
    is the slot that the component names for exactly this. `HasSlotController#test` asks whether the
    **`footer`** slot holds anything to decide if the card draws a footer at all, and the
    `with-footer` attribute does not survive the first update. Thus a card with `footer-actions` and
    no `footer` hides **both** controls, and it gives no message. The two buttons also go in ONE
    element, because the footer lays its own children out.
  - ⚠️ **The browser cannot read the page itself.** The CSP of the admin has `connect-src :self`,
    and another host sends no CORS header. Thus this app reads it. **Do not try to move this into
    the browser.**
  - ⚠️ **The picture is a proxy of ours, and never the `og:image` itself**, because `img-src` is
    `:self`. `GET /social/preview/image` sends it, exactly as the Course maps page proxies a Mapbox
    render.
  - ⚠️ **The parameter of that proxy is the URL of the PAGE, and not of the picture.** Thus a caller
    cannot name any URL for this app to get: the picture is always the one that the `og:` tags of
    that page name.
  - **It shows the bytes that go up as the blob**, because it calls the same `Bluesky#card_image`.
    That method is public for this reason alone.
  - The card is a **`<wa-card>`** with the picture in its `media` slot. ⚠️ **`with-media` follows
    the picture, and it is not in the markup.** That component has no `:has-slotted` to read, thus
    the flag is the only thing that tells it to draw the media section, and a card with the flag and
    no picture draws an empty band.
  - ⚠️ **`Bluesky` requires `vips` inside `#shrink`, and NOT at the top of the file.** libvips is a
    native library. A require at the top makes each path of that class need it, thus a post with a
    small picture, and each preview, would fail on a machine with no libvips. `#shrink` also rescues
    **`LoadError`**, which is not a `StandardError`: without that name the page gives a 500 in place
    of a card with no picture. `BlurhashPlaceholder` keeps its require at the top, because that
    class exists only to use libvips.
  - `OpenGraph#fetch` caches for 15 minutes, thus a preview also **warms the cache** that the post
    job reads a moment later.
- **One body goes to the three networks, and the limit is 300**, which is the limit of Bluesky and
  the shortest of the three. `SocialPresenter::BODY_LIMIT` and `WARN_AT` hold the two numbers, the
  view writes them into the markup, and the Stimulus controller reads them there.
  - ⚠️ **Do not use the `maxlength` or the `with-count` of `wa-textarea`.** Both measure UTF-16 code
    units, and Bluesky counts **graphemes**: one emoji is 1 there and 2 or more here. The controller
    counts with `Intl.Segmenter`.
  - ⚠️ **The count warns and never stops a keystroke.** `maxlength` would refuse one with no message.
- **The link is not part of the body, and the count does not hold it.** Each network attaches a link
  differently: Threads makes an attachment, Bluesky makes an embed, and Mastodon renders it inline.
  Thus the code that posts decides that, and this page keeps the URL of the entry beside the text.
  - ⚠️ **The one exception: a page that gives NO og: tags.** Bluesky draws its card from the title,
    the description, and the picture, thus a page with none of the three makes an empty box with a
    host name in it. `OpenGraph::Card#embeddable?` is the rule, and a card that fails it gets **no
    embed**: the link goes in the words instead, exactly as it does at Mastodon.
    `Admin::SocialController#bluesky_text` and `BlueskyPostJob` compose the same string, thus the
    count and the post cannot disagree.
  - ⚠️ **That link then uses characters, thus `#post_error` counts it.** Without that check the job
    composes a longer text than the page measured, `Bluesky#post!` raises, and the job retries for
    24 hours. `admin.social.errors.too_long_link` is the message, and it says what it counted.
  - ⚠️ **The length check therefore READS the page at the submit.** `OpenGraph` caches for 15
    minutes and the preview warms that cache, thus it nearly always reads a copy from Redis. A read
    that fails gives a blank card, which is not `embeddable?`; thus a failure puts the link in the
    words, which is the same answer that the job reaches at that moment.
  - ⚠️ **Nothing on the page says this in words.** The Preview panel shows the link inside the
    words of the Bluesky row, and that is the whole message. A line that says "this page has no
    preview card" only repeats what the card already shows.
- ⚠️ **Do not add a Bluesky threadgate or postgate control.** The owner read those options and
  refused them. This page has no control for one network alone.
- **`POST /social` adds one post job for each network and answers with a 303.** A refusal renders the page again
  with a **422** and keeps the draft, and it does not redirect. ⚠️ The draft is the expensive part
  of this page, thus a redirect that loses 300 characters is worse than a page that renders again.
  `SocialPresenter` takes `body:`, `article_url:`, and `selected:` for that.
  - ⚠️ **The action strips the body one time, and each service gets that text.** Without that, a
    body with a newline at its end went to Bluesky as it was and to Mastodon with the newline
    removed, and the count on the page named a third number.
- **Each connected row is ticked on the first load.** `SocialPresenter` reads `selected: nil` as
  "tick each connected network", and an array, which is what a submit that fails passes back, as
  the choice of the owner. Thus an empty array ticks nothing.
- ⚠️ **The controller makes the record key and gives it to the job.** `Bluesky#post!` writes with
  `putRecord` at that key, thus the 24-hour retry of `ApplicationJob` replaces one post and never
  adds a second one to the feed. **`createRecord` makes its own key, thus each retry there is a new
  post.** This is the one thing that makes the job safe to do more than one time. Refer to
  **Posting to Bluesky**.
- **A switch opens a date and a time, and `perform_at` then schedules the job.** With the switch
  off the action calls `perform_async`. The **label of the submit button** says which of the two the
  form does — "Post now", or "Schedule for Sep 3, 9:00 AM" — exactly as the Republish dialog
  does, because the switch alone is easy to miss.
  - ⚠️ **The browser sends its own IANA zone in a hidden field, and that is what makes a date field
    safe here.** A date and a time carry **no** zone. The Republish dialog dropped its date field
    for that reason and takes minutes from now instead, and a reader of that ⚠️ must know why this
    page is different. `social_controller.js` writes
    `Intl.DateTimeFormat().resolvedOptions().timeZone` into a hidden field. The page does **not**
    print that zone: it is the zone of the browser, thus the time that the owner picks is already
    the time that they mean.
  - ⚠️ **The action checks that zone against the zones that Rails knows.** That value comes from the
    browser, thus one with a mistake must give the fallback and never an exception. When the
    Stimulus controller did not run, the field is empty, and `TimeZoneResolver.default`
    (`TIME_ZONE`) is the meaning. ⚠️ That is a fallback for a script error, and **not** a page that
    works with no JavaScript: each `wa-*` control needs JavaScript to be part of its form, thus a
    browser with no JavaScript submits no body and no link at all.
  - ⚠️ **The action matches the shape of the date and the time before it parses them.**
    `Time.zone.parse("garbage 09:00")` gives today at 09:00, thus a value with a mistake would
    schedule a post for today.
  - ⚠️ **`required` on the date and the time follows the switch, and it is not in the markup.** A
    required control inside the hidden block would refuse "Post now", and a browser cannot show
    that message on an element that nobody can see.
  - ⚠️ **A moment that has PASSED is not a schedule, and it is not an error either**: the draft goes
    out at once. `#scheduled_at` gives nil for it, thus it takes the path of a post with no
    schedule, and `#picked_moment` is the raw value that `#schedule_error` reads to tell "no date at
    all" from "a date that went by". The label of the submit button says **"Post now"** for that
    same draft, and a refusal here would make that button a liar.
  - **The submit button is off while the draft cannot go out**: a post with no words, a post past
    the limit, no network ticked, or the schedule switch on with no moment in its two fields.
    ⚠️ A moment that has **passed** is not that last case: it is a complete answer that means "post
    now", thus the button stays on and its label says so. ⚠️ That check is **stricter than the server**, which drops a
    block with nothing at all in it. A block that the owner added and left empty turns the button
    off instead, thus the page never asks them to guess which post is the problem.
  - ⚠️ **There is no limit on how far ahead a post can go, on purpose.** A post about a race can
    wait for the race. Thus the date field has a `min` and no `max`, and the job sits in the
    scheduled set of Sidekiq until it runs. The action refuses only a moment in the **past**, which
    would fire at once.
  - **There is no page that lists the scheduled posts.** The **Scheduled** tab of `/sidekiq` shows
    them, and that is where you delete one. ⚠️ Unlike `SiteBuildJob`, this job keeps **no** jid and
    a new schedule cancels nothing: the owner can line up more than one post, and each is its own
    job with its own record key.
- ⚠️ **There is ONE JOB FOR EACH NETWORK, and not one job for all of them.**
  `Admin::SocialController::NETWORKS` is the one table of the networks: the job, and the
  method that reads the state of each one. ⚠️ The **name** is not in that table: it is
  `admin.networks.*` in the locale file, which the Connected apps page reads as well. The action adds one job for each network that the owner
  ticked. **This is the point**: a failure at one service retries that
  service alone, and a network that already posted is never sent again. An earlier version had one
  job that posted to each network, and a retry of it went back to every one of them.
- ⚠️ **One key goes to all three jobs, and each attempt of each job carries it.** `Bluesky.new_tid`
  makes it. Bluesky writes at that **record key**, Mastodon sends it as its **`Idempotency-Key`**,
  and Threads keeps its **media container** below it. That is what makes the retry of each job safe.
- ⚠️ **The action posts only to a network that has an account.** A row with no account renders
  `disabled`, thus a browser cannot tick it, but a request that a person writes by hand can. Without
  that check the job would raise "not connected" and retry for 24 hours. ⚠️ For Threads the check
  is `usable?` and not `connected?`: an expired token is connected and cannot post, and the row
  then says so.
- **The three rows are always on the page**, and a row with no account is `disabled` with a link to
  Connected apps. That is different from Connected apps, which hides such a card: there the card
  offers an action that would fail, and here a disabled row says why one of three names cannot take
  a post.
- ⚠️ **The page renders with no account connected, and the nav always holds it.** Each of the three
  rows is then disabled. It is a draft screen, thus the owner must be able to look at it and change
  it before an account exists. Do not gate it on the connection state.
  ⚠️ `SocialController#social_networks` reads each state from **Redis**, and no service makes an HTTP
  request, for the same reason as the Connected apps page.

#### Mentions

Each network writes a mention in its own way, and the same person has a different handle at each
one, or no account at all: Bluesky takes `@handle.tld` and this app resolves it to a DID, Mastodon
takes `@user@instance` and Threads takes `@username`, and each instance parses its own text. Thus
one body cannot hold a mention that is correct everywhere.

⚠️ **The danger is not a mention that does nothing, it is a mention that tags a STRANGER.**
`@tony.bsky.social` is correct at Bluesky, and Threads reads `@tony` in it and tags whoever holds
that name. Nothing reports that.

The owner writes a short token, and the composer asks what that person is called at each network.
`SocialMentions` writes those words into the text.

- ⚠️ **The map is part of the DRAFT, and nothing stores it.** It goes out with the form and it is
  gone after the post. There is no directory, no Redis key, and no admin page: a handle that a store
  holds goes out of date, and a name is needed for one draft only.
- ⚠️ **The map is THREAD-LEVEL.** One row covers a token that more than one post holds.
- ⚠️ **A row asks about the CONNECTED networks only.** That is different from the "Post to" list,
  which keeps a disabled row to say why one of three names cannot take a post. Here there is nothing
  to say, thus a field for an account that cannot post is only noise. With no account at all the
  section stays away, and each token still loses its "@" on the server.
- ⚠️ **A field takes a handle OR plain words**, and the shape of the value decides which:

  | The field | What goes in the text |
  |---|---|
  | Blank | The token as the owner wrote it, with the `@` removed. `@Tony` gives `Tony`. |
  | The shape of a handle of **that** network | `@` and the handle. |
  | Anything else | The words, ⚠️ **with every `@` removed**. |

  ⚠️ **The shape check SELECTS, and PLAIN WORDS are never refused.** "Anthony Edwards" is the
  correct answer for a person with no account there.
  ⚠️ **The one refusal is a handle of a DIFFERENT network** — a Mastodon handle in the Bluesky
  field, and so on. Such a value is otherwise mangled with no message: it is not a domain, thus it
  becomes plain words and every "@" comes out of the middle of it.
  ⚠️ **`SocialMentions::DIAGNOSTIC_SHAPES` holds Bluesky and Mastodon ALONE, and that is
  deliberate.** The shape of Threads is letters, digits, a period, and an underscore, thus a plain
  first name matches it. A check against it would refuse "Tony" in the Mastodon field, which is the
  thing that this feature exists to permit. The cost is that a Bluesky handle in the Threads field
  is not named: it is a valid Threads username as well, and no rule can tell it from a real one.
  ⚠️ The check reads the **ticked** networks only. A field of a network that the draft does not
  post to changes nothing.
  ⚠️ **A `@` only ever comes back from the handle branch**, which knows the shape. Plain words carry
  none: `@Anthony Edwards` would otherwise reach Threads, which reads `@Anthony`.
  ⚠️ **A blank field gives the spelling of the OCCURRENCE and not the key of the map.** Thus `@Tony`
  reads as a name, and the owner writes the token as they write the name.
- ⚠️ **The substitution is in the ACTION, and not in a job and not in a service.** The action makes
  one payload for each network. Thus the three jobs and the three services need no change, each
  attempt of a job carries the same text, and the map never goes into Redis.
  ⚠️ **The record keys are still made ONE time, outside that loop.** The three networks get a
  different text and they must share one key for each post.
- ⚠️ **The server finds each token itself and reads the map as a lookup only.** Thus a token with no
  row still loses its `@`, and a submit with no `mentions` at all turns every mention into a plain
  name. That is the safe direction.
- ⚠️ **The count measures the BLUESKY text**, after all three steps. `@tony` is 5 characters and
  `@tony.bsky.social` is 17, thus a count of the raw words would pass a draft that Bluesky then
  refuses. `#post_error` and
  `social_post_controller.js` measure the same string, the message says "with the Bluesky handles",
  and `SocialPresenter#bluesky_length` writes the first count. The count uses Bluesky even when
  Bluesky is not ticked: 300 is the limit of this page.
- ⚠️ **Mastodon and Threads now need a length check of their own.** Only the Bluesky text is capped
  at 300, and a plain name is longer than a handle. Without that check a long draft raises in the
  job and retries for 24 hours. The comments in those two services say so.
- **The action asks Bluesky about each handle** and refuses a draft that names one that the PDS does
  not know, because `#mention_facets` drops such a handle with no message. It asks about a value
  with the SHAPE of a handle only.
  ⚠️ **`Bluesky#handle_missing?` is true for a definite refusal ALONE**, because `#resolve_handle`
  gives nil for "no such handle" and for "no answer" both.
  ⚠️ **A BUDGET, and not the timeout of one call, is what makes it fail open.** Several slow calls
  together pass the 20-second rack-timeout, and `Rack::Timeout::RequestTimeoutException` is not a
  `StandardError`, thus no rescue would catch it and the submit would give a 500.
- ⚠️ **The Bluesky map reaches each post block as a plain `data-` attribute, and NOT a Stimulus
  value.** A value arrives through a MutationObserver, thus it is not synchronous, and
  `social#canPost` reads the count line that the block writes. The submit button would then follow
  the keystroke before the current one.
- **The browser RECONCILES the rows and never renders them again**, after a debounce: a token churns
  while the owner types it. A row that goes away keeps its values in a Map, thus a token that comes
  back gets them again. ⚠️ The rows are not put in order while the focus is inside the section,
  because a node that moves loses the focus.
- **A token that is already a handle seeds its own field**, thus `@tony.bsky.social` in the body
  still works at Bluesky with no typing. ⚠️ **Nothing seeds Threads**: a bare `@name` is exactly the
  ambiguous case.

⚠️ **The token pattern and the URL pattern are in Ruby and in JavaScript**, because the count must
follow each keystroke. They are **strings** in both files, and not Regexp literals: an interpolated
Ruby Regexp gives a source with `(?-mix:…)` in it, which JavaScript cannot parse.
`spec/contracts/social_mentions_contract_spec.rb` compares them.
⚠️ A difference fails **safe** in both directions: a token that only the browser finds gives a row
that the action ignores, and a token that only Ruby finds gets no row, thus its `@` comes off.

#### Typography

The body of a post gets the **SmartyPants typography**: `It's a "big" day...` posts as
`It's a "big" day…`. The owner writes on a keyboard, and the post carries the marks that the
sentence needs.

⚠️ **It is the SAME typography as the blog.** `Typography` extends `MarkdownHelper` and calls its
`#smartypants`, thus a post and the article that it links to cannot use a different apostrophe.
**Do not write a second set of rules.**

⚠️ **A curly quotation mark is a CHARACTER and not rich text, thus each of the three networks gets
it.** That is the difference from a Markdown link, which Bluesky alone can take.

⚠️ **An address goes through with NO change, and that is why this class exists** and the helper is
not called directly. SmartyPants reads the characters of a URL as punctuation:
`example.com/a--b` becomes an en dash, `/a...b` becomes an ellipsis, and `?q="a"` becomes curly
quotation marks. Each of those is a link that is dead, and nothing reports it.

- ⚠️ **It MASKS each address, and it does not split the text at one.** SmartyPants decides the
  direction of a quotation mark from the characters at each side of it, thus it must read the whole
  sentence at one time. With a split, `He said "see <link> now"` opens the quotation and never
  closes it: the two marks are in different pieces. `Typography::PLACEHOLDER` is U+FFFC, and the
  method **gives the words back with no typography at all** when a mask goes missing — a straight
  apostrophe is a small thing, and an address that another address replaced is a link to the wrong
  page.
- ⚠️ **SmartyPants writes HTML entities**, because it is a renderer of HTML: `&rsquo;` and not `’`.
  A post holds characters, thus the `HTMLEntities` decode is necessary and not decoration.
- ⚠️ `Bluesky::URL_PATTERN` is the rule for what an address is, as it is for `SocialMentions`. It
  also covers the `](https://…)` of a Markdown link and a `[name]: https://…` definition, because
  each of those puts the address after a character that is not a word character.
- The order of the whole pipeline is **the mentions, then the typography, then the Markdown**.
  ⚠️ A handle can hold no quotation mark and no dash pair, thus nothing that the first step writes
  is read as punctuation by the second. ⚠️ The typography must run **before** the Markdown parse,
  because that parse makes the byte offsets of each facet: a `...` that became `…` afterwards would
  move every facet after it.
- ⚠️ **The message of a post that is too long names the handles only when a MENTION made it
  longer.** `#post_error` reads `#mentioned` and not `#text_for` to decide that, because the
  typography runs on every draft.

⚠️ **The browser needs its own copy for the count**, and `app/javascript/lib/typography.js` holds
the part of the rules that changes a LENGTH. **It writes no quotation mark, and that is correct**:
`"` becomes `“` and `'` becomes `’`, and each is one character in place of one, thus the direction
of a quotation mark cannot change a count. That is the hard half of SmartyPants and the half that no
small copy could match, and it does not have to be matched.

What is left is context-free, and `spec/contracts/typography_contract_spec.rb` runs both files with
node and compares the lengths:

```
...  or  . . .   ->  …      three dots, or three with ONE space between each
---              ->  —      the dashes run longest first: four give "—-" and five give "—–"
--               ->  –
```

⚠️ **That file is for the COUNT and it must never render text that a person reads.** It would give
a post with straight quotation marks.

#### Markdown links

The body of a post takes a **Markdown link**, in three forms:

```
[words](https://example.com)          inline
[words][name] … [name]: https://…     a reference, and its definition on a line of its own
[name] … [name]: https://…            a short reference, where the words are the name
```

⚠️ **Only Bluesky can take one, and that is the reason for the whole feature.** Its rich text puts
the address in a **facet**, thus the words carry the link and the URL uses **none** of the 300
characters. Mastodon and Threads post plain words: the same draft would reach a reader as
`[my post](https://…)`, with the address in the middle of the sentence.

Thus **a Markdown link in any post turns the other two networks off**. `social_controller.js`
unticks and disables those two rows at the keystroke that makes the first link, and their hint says
why. ⚠️ **The action refuses such a request as well**, and that is not a repeat of the composer: a
row that a browser cannot tick, a request that a person writes by hand can.

- ⚠️ **It is THREAD-LEVEL.** A thread goes to a network as one unit, thus one link in one post
  decides the whole draft. The action and the composer read it the same way.
- ⚠️ **The composer keeps the ticks that the owner had**, thus a link that they write and then
  remove gives the draft its networks back. It restores them **only at the change**, and not at each
  keystroke: a restore at every one of them would put back a tick that the owner had just taken off.
- ⚠️ **`MarkdownLinks` is a small grammar and NOT a Markdown renderer.** It knows a link and nothing
  else: no emphasis, no heading, no code, and no escape. A post is 300 characters of a person
  writing a sentence, and each other rule of Markdown would only turn plain words into markup that
  the owner did not ask for. **Do not add a Markdown library for this.**
- ⚠️ **The address must be http or https, and a span with anything else stays exactly as it is**,
  brackets and parentheses and all. Thus "I ate [a lot](really)" is a sentence, `[wild]` with no
  definition is a word in brackets, and `.links?` answers false for both. That test is what turns
  the two checkboxes off, thus it must never fire on an ordinary sentence.
- ⚠️ **A bare URL is not Markdown.** Each of the three networks makes a link of one, thus a draft
  that holds one still goes to all of them.
- ⚠️ **`Bluesky#post!` renders the Markdown, and the action does NOT.** The job carries the words
  that the owner wrote, thus each attempt of that job makes the same record text and the same
  facets from one parse. `Bluesky.link_ranges` is the one list of the links of a post: `#build_facets`
  makes a facet from each entry, and the preview renders each entry as an `<a>`. Thus the dialog
  cannot show a link that the post does not make.
- ⚠️ **`Bluesky.post_length` renders first**, thus the count measures what the **record** will hold:
  `[my post](https://example.com/a)` is 7 characters and not 30. Without that the action would
  refuse a draft that Bluesky takes.
- ⚠️ **The offsets of `MarkdownLinks::Link` are CHARACTERS**, and `Bluesky#link_facet` makes the
  bytes that a record needs. One accented letter is 1 character and 2 bytes.
- ⚠️ **The Markdown is the LAST of the three steps**: the mentions, then the typography, then this.
  Refer to **Typography** above for the reason that the order cannot change.

⚠️ **The grammar is in Ruby and in JavaScript**, because the count must follow each keystroke and
the two checkboxes must go off at the keystroke that makes the first link.
⚠️ **A difference does NOT fail safe here**, and that is the difference from the mention contract: a
browser that renders a link that Ruby does not shows a count that is too small, and the action then
refuses a draft that the page called correct. Thus
`spec/contracts/markdown_links_contract_spec.rb` does not compare the patterns alone — it **runs the
JavaScript file with node** over the same drafts and compares the answers. The grammar is an
algorithm and not one regular expression. **Add a row to `DRAFTS` there for each rule that you add.**
⚠️ **The browser copy carries no offsets, on purpose.** Ruby counts code points and JavaScript counts
UTF-16 code units: one emoji of a family is 5 and 8. An offset from that file would be a number that
looks correct and is not, and nothing in the browser needs one.

#### The Threads topic

A **Threads topic** field below the "Post to" list. Meta calls it `topic_tag`, and it is the
parameter that puts a post under a topic in the Threads app.

⚠️ **One field names the whole draft, and EVERY post of a thread carries the topic.** Meta takes
one topic for each post, and no documentation says that a reply inherits the topic of its root, thus
`#create` sends it with each post.

⚠️ **A REPLY DOES NOT INHERIT THE TOPIC OF ITS ROOT**, and two threads of two posts measured it:

| What `#create` sent | The root | The second post |
|---|---|---|
| The topic on **each** post | the topic, and "1/2" | the topic, and "· Author" |
| The topic on the **first** post | the topic, and **no** number | **no topic**, and "· Author" |

Thus the topic goes on every post. The second row is the reason: the reply lost the topic
completely, **and the root lost its number as well**. Threads appears to read a chain of posts that
carry one topic as one thread, thus a topic on the first post alone makes two posts that are only a
post and a reply. **Do not send it on the first post alone again.**

⚠️ **The "2/2" of a reply is not reachable from the API**, and it was absent in both of those
tests. The composer of Threads numbers both posts. `reply_to_id` is the one way to chain a post,
there is no endpoint that takes a whole thread, and no parameter asks for that number. Accept it.

⚠️ Meta takes `topic_tag` on a reply container with no complaint. If that ever changes, the
container fails and the job retries for 24 hours; `#create_container` names the fields that it sent
in the message that it raises, thus such a failure reports `topic_tag` and does not read as an
empty 500.

⚠️ **Bluesky and Mastodon have no equivalent**, thus the field shows only while the Threads row can
take a post **and** is ticked. `social#applyTopic` reads `disabled` as well as `checked`, thus one
rule covers a network with no account **and** a row that a Markdown link turned off. It runs after
`applyMarkdown`, which is what disables that row.

- **The server renders the field hidden when the rule says so** (`SocialPresenter#topic?`), thus it
  does not show for a moment before the Stimulus controller runs.
- ⚠️ **Nothing clears the field while it is hidden.** A topic that the owner wrote survives an
  untick and a tick again, and the action reads the value only while the Threads row is ticked. A
  topic that Meta would refuse is therefore **not** an error for a draft that goes nowhere near
  Threads.
- **The limits are `Threads::TOPIC_MAX_CHARACTERS` (50) and `TOPIC_FORBIDDEN`**, which is a period
  and an ampersand. ⚠️ The action refuses a topic outside those, because Meta refuses the
  **container** and `ThreadsPostJob` would then retry a draft that can never work, for 24 hours.
- ⚠️ **`Threads.normalize_topic` removes a leading `#`.** The parameter takes the words alone: a
  hash sign belongs to a tag that is IN the text, and one here would become part of the topic.
- The preview shows the topic on the **Threads row of every post**, which is where each post
  carries it.

⚠️ **There is NO way to look up a topic, and there is no list to pick one from.** The Threads
keyword search (`/keyword_search`, with `search_mode=TAG`) searches **posts** that carry a topic,
and it takes a `q` that you must already know. Meta publishes no endpoint that gives the topics
themselves. Thus the field is a plain text input and the owner types the words.
⚠️ Do not add a picker or a suggestion list without an endpoint that answers "which topics exist".
`threads_trending_topics` is a permission that the Meta dashboard offers and that the owner did not
enable, and it is **not** in `Threads::SCOPES`; what it returns was not confirmed, and a list of
*trending* topics is not a search in any case.

#### The preview

A **Write** and a **Preview** tab. The Preview panel shows the draft as each network will receive
it, with the count and the limit of that network. It posts nothing.

⚠️ **The thread is the only thing inside those panels.** The mentions, the "Post to" list, the
schedule, and the submit button stay below them and show in both, because each one changes what a
preview shows. `social#tabShown` reads the draft when the owner opens the Preview tab, and
`social#schedulePreviewRefresh` reads it again after a change to a mention or to the topic — the
two things that change the TEXT and that only the server can write. The words of a post cannot
change while that panel is on screen: they are in the Write panel.

⚠️ **Unticking a network hides its row AT ONCE and asks for nothing.** The action answers with each
**connected** network, and `social#filterPreview` hides the rows of the ones that the owner did not
tick. Thus the panel shows the draft as it will be sent. With no network ticked it shows one line
that says so.

⚠️ **The Preview TAB is off while the draft holds nothing**, and that is `canPreview` and NOT
`canPost`: a draft that is past the limit, or that ticks no network, is exactly the one that the
owner wants to look at.

⚠️ **`wa-tab-group`, `wa-tab`, and `wa-tab-panel` are three separate imports** in
`app/javascript/admin.js`. A group imports neither its tabs nor its panels, and a page with only
the group renders the words of every panel one after the other, with no tab at all.
⚠️ A panel that is not active is `display: none`, thus its fields are still in the form and a
submit sends them.

Three things make the texts different, and the owner could see none of them before this dialog:

- **A mention.** Refer to the part above.
- **The link.** `Mastodon#post!` joins it into the **text**. Bluesky makes an embed of it and
  Threads makes an attachment, thus it is not in the text of either one. The dialog says where the
  link went for those two. ⚠️ A page with no og: tags gives Bluesky no embed, thus its link is in
  the words there as well, and the Bluesky row then carries no card.
- **A Markdown link.** The Bluesky row shows the **rendered** text, thus the owner reads the words
  that a post will hold. ⚠️ A draft that holds one shows **Bluesky alone**: to render the other two
  would show a text that this app refuses to post. The dialog says nothing about that, on purpose —
  the two rows of "Post to" are already off, and their hint gives the reason.

**Each link is a link in the dialog.** The action sends the text in `segments`
(`[{ text: }, { text:, url: }, …]`) and the browser writes an `<a>` for a piece that has a `url`.

- ⚠️ **A Markdown link shows its WORDS and never its address**, thus an `<a>` is the only thing that
  says where those words point. Without it the owner cannot check a link at all.
- A **bare URL** that the owner pasted is a link at each of the three networks, and it is one here
  as well. For Mastodon that includes the link of the field, which `Mastodon.compose` joins into the
  text.
- ⚠️ **`Bluesky.link_ranges` is the rule for the three networks, and not for Bluesky alone.** Each
  instance linkifies a bare URL with a rule of its own, thus the dialog says "these words are an
  address" and not "Mastodon will make exactly this a link". `SocialMentions` reads that same
  pattern for the same reason.
- ⚠️ **The browser writes each piece with `textContent` and `href`, and never with HTML.** Both URL
  patterns start with `https?://`, thus no draft can make a `javascript:` link in the admin.
- ⚠️ **The `<a>` needs no style of its own.** Web Awesome gives a bare anchor the brand color and an
  underline, and a measurement in a browser gave the same color for a styled one and a plain one.

⚠️ **The value of the dialog is that it CANNOT be wrong, thus it copies nothing:**

- `#preview_text` calls the same `#posts`, `#mention_rows`, and `#text_for` that `#create` calls,
  and the panel posts the same field names as a real submit. Thus a change to the substitution
  reaches both.
- ⚠️ **The Bluesky rows carry the website CARD, and not a line that describes one.** This app builds
  that embed (`Bluesky#build_card`) from the same og: tags, thus it can draw it. `#card_json`
  answers the card below the link field **and** this one, thus the two cannot describe one page
  differently, and it is memoized by URL for a thread that names one link twice. Threads keeps its
  note: Meta renders its own attachment and this app has nothing to show.
  ⚠️ This is the one other service that the action calls. `OpenGraph#fetch` caches for 15 minutes,
  thus a preview also warms the cache that the post job reads.
- **`Mastodon.compose` makes the status**, and `Mastodon#post!` calls that same method.
- **`NETWORKS` holds the `limit` of each network**, and `#length_for` holds the count rule of each
  one: graphemes for Bluesky, characters for the other two, and a URL at `Mastodon::URL_WEIGHT`.
  `#network_length_error` and the preview both read them. Without one place the page could call a
  draft correct and the action could then refuse it. A spec pins that agreement in both directions.

The rules of the dialog:

- ⚠️ There is no Preview **button** any more, and that removes the old trap: `<wa-button>` is
  form-associated, thus one in a form with no `type="button"` submits it. A `<wa-tab>` is not a
  button and it cannot submit. The buttons of the remove dialog still carry that attribute.
- ⚠️ **It sends the CSRF token in a header.** The admin does not skip the forgery protection, and
  `config.action_controller.allow_forgery_protection` is **off in the test environment**. Thus each
  ordinary example passes with no token and none of them proves this. One example turns that
  protection on and posts with the token of the page, and a second one checks that the same request
  with no token is refused. Without the header the dialog would fail in production alone.
- ⚠️ **The dialog carries `data-controller="dialog"`**, as each dialog of the admin does. Turbo makes
  its snapshot of the DOM as it is, thus one that is open when the owner navigates away comes back
  open on a restoration visit.
- The markup opens it with `data-dialog="open <id>"`, thus no code of ours opens it and the action
  only fills it. It reads the draft **at the click**, thus it needs no debounce: that is the
  difference from the link preview, which follows the typing.
- ⚠️ The Republish dialog is a **sibling of `<wa-page>`** because the nav holds it, and that
  component moves its `slot="navigation"` content. This one is in the page and holds no form
  control, thus it is safe inside the `<form>` and the controller reaches it with a target.
- A draft of one post gets **no label**: a number for a thread of one says nothing.
- ⚠️ **The button is OFF while the draft holds nothing**, and it is `disabled` in the markup as
  well, thus it is off before Stimulus connects. A dialog that opens to say "nothing yet" is worse
  than a button that is off. The rule reads text OR link, which is the rule that `#posts` follows.
  ⚠️ It is **not** `canPost`: a draft that is past the limit, or that ticks no network, is exactly
  the draft that the owner wants to look at.
- A request that fails writes **one line** in the dialog, and a dialog that opens and stays blank
  says nothing at all. The line for an answer with no post stays as a fallback, and the button
  above is what keeps it off the ordinary path.

#### A thread

The owner adds posts below the first, and each one has its own words and its own optional link.

- **The form sends `posts[][text]` and `posts[][link]`.** ⚠️ **Rails starts a new hash when a key
  repeats, thus both fields must render for every block, in the same order.** A block that omits one
  moves each pair below it by one. There is **no index in the name**, on purpose: an index needs
  renumbering in the browser at each add and each remove, and that is the thing that breaks.
- **The view holds a `<template>` of one empty block**, and the outer `social` controller clones it.
  ⚠️ The content of a `<template>` is a separate fragment: `querySelectorAll` does not reach it, thus
  Stimulus does not count the block inside it and its fields are not in the form.
- ⚠️ **Each block is its own `social-post` controller**, which owns that block's count, spinner, and
  preview. The outer controller never reaches into a block. A flat list of targets would need an
  index at every call.
- ⚠️ **The per-post label is `data-social-target="postLabel"` and NOT `label`.** The submit button
  owns `label`, and one name for both made `labelTarget` find the first post and write "Post now"
  into it.
- **`SocialPresenter::MAX_POSTS` is 25.** It is a guard against a runaway form and not a rule of any
  network.
- A block with **nothing at all** in it is dropped, thus an empty block that the owner added and
  left alone does not refuse the draft.
- ⚠️ **A remove asks first, for a block that holds something.** A post is as much as 300 characters
  and a link, and nothing puts it back: there is no undo and the browser keeps no copy. A block that
  is still empty goes at once, because a question about nothing is only noise. The rule reads text
  OR link, which is the rule that `#posts` follows.
  - ⚠️ **There is ONE dialog for the whole thread**, and not one for each post: a block comes from a
    `<template>` that the browser clones, thus a dialog inside it would give more than one element
    the same id. `social#removePost` remembers which post asked.
  - ⚠️ **`clearRemoval` runs at `wa-hide`, and NOT at `wa-after-hide`.** The second one waits for
    the close animation to be complete, and a measurement in a browser gave a `wa-hide` with **no**
    `wa-after-hide` after it. Thus a handler on that event never runs at all. This applies to each
    dialog of the admin, and not to this one alone.
  - ⚠️ `#confirmRemove` reads the post **before** it closes the dialog, because the close fires
    `wa-hide`, which forgets it.
- ⚠️ **A message names the post** — "Post 2 is 301 characters." — because a thread has more than one
  and a plain message does not say which one is wrong. With one post the messages keep their
  singular form.

**The chain.** ⚠️ **There is one job for each POST, and not one job for the whole thread.** Each job
posts its own index and then adds the job of the one below it.

- ⚠️ **This is what makes a retry safe, and it needs no new Redis store**: a failure runs **one**
  post again, and that post is idempotent for the reason that each network already had — Bluesky
  writes with `putRecord` at its own key, Mastodon sends that key as its `Idempotency-Key`, and
  Threads keeps its media container below it. A single job for the whole chain would, on a retry, go
  back to the posts that already went out.
- ⚠️ **The controller makes one key for each post**, and the three networks share those keys. The
  reply reference travels in the **job arguments**, thus it is the same at each attempt.
- ⚠️ **Only the FIRST job of each network is scheduled.** The rest of the chain goes out with it.
- The reply of each network: Bluesky takes `reply: { root:, parent: }`, two strongRefs, thus
  `AtProto#put_record` answers with `{ "uri" =>, "cid" => }` and not with a Boolean. Mastodon takes
  `in_reply_to_id`, thus `Mastodon#post!` answers with the `id` as well as the URL, and the Redis
  value that it remembers holds both. Threads takes `reply_to_id` **on the container**.
- ⚠️ **The root of a Bluesky thread is the FIRST post, and the parent is the one just above.** The
  job carries the root through the chain and never makes it again.
- ⚠️ **A thread that fails part of the way through leaves the posts above it published**, on that
  network only. This is accepted: the alternative is to delete posts that are already public, and a
  reader may have replied to one. Each other network has its own chain and is unaffected.

### Posting to Bluesky

`Bluesky` writes an `app.bsky.feed.post`. ⚠️ **It is not `StandardSite`**, which writes the
`site.standard.*` mirror of the blog. The two are different records for different readers, and they
share the account, the session, and the blob upload through the **`AtProto`** concern.

⚠️ **`AtProto` exists because both classes talk to the same PDS with the same credentials**, from
`BlueskyCredentials`. Two session implementations would need two edits when the account, the
endpoint, or the authentication changes, and the copy that a person forgets fails only at the next
publish. An includer defines `at_proto_label`, which names it in each log line and each error
report, and it must inherit `ApplicationService` for `report_upstream_error`.

- ⚠️ **`post!` takes the `rkey` from its caller and uses `putRecord`.** `Bluesky.new_tid` makes that
  key from the clock, thus a later post sorts after an earlier one. `StandardSite.tid(seed)` is the
  **other** kind of key: it is content-addressed, because the same entry must always give the same
  rkey.
- ⚠️ **The link of a post is a website card (`app.bsky.embed.external`), and it is NOT in the
  text.** Thus the URL uses none of the 300 characters. ⚠️ **A page that gives no og: tags is the
  exception**: `#post!` gets no card, and the caller puts that link in the text with
  `Bluesky.compose`. Refer to **The Social media page**.
- ⚠️ **A card of a post of THIS site is a standard.site card, and each other one is an ordinary
  link card.** The embed stays an `app.bsky.embed.external` in both conditions, and
  **`associatedRefs`** is the one thing that makes the difference: a list of
  `com.atproto.repo.strongRef`, the `site.standard.document` first and the
  `site.standard.publication` second. Refer to **The standard.site card** below.
- ⚠️ **The card comes from the `og:` tags of the page, through `OpenGraph`, and NOT from
  Contentful.** Two reasons, and each one is enough: a **Short has no cover image**, and the link
  can be a page on **another site**. `OpenGraph#fetch` reads `og:title`, `og:description`, and
  `og:image`, and it falls back to `<title>`, `meta[name=description]`, and `twitter:image`.
  - **It never raises.** A page with no tags, or a host that is away, gives a card with the URL
    alone. ⚠️ Such a card is not `embeddable?`, thus the post gets no embed and its link goes in
    the words.
  - ⚠️ It sends a **User-Agent** of its own. Many hosts give a 403 to the default one, and the card
    is then empty with no reason.
  - It reads the first `MAX_BYTES` of the page through `download` and stops there. The tags are in
    the `<head>`. A relative `og:image` resolves against the final URL, after each redirect.
  - Redis caches each card for 15 minutes, thus a retry of the job does not ask the page again.
- **The thumbnail is the `og:image`, whatever host holds it.** `Bluesky#upload_card_image` gets it
  and uploads it as a blob. ⚠️ A blob past `MAX_BLOB_BYTES` fails at **`putRecord`** and not at the
  upload, thus the whole post would go away and the message would name the embed. For that reason
  the code shrinks an oversized picture to 1200px wide with **libvips**, which this app already
  needs for the blurhash placeholders, and it drops a picture that is still past the limit after
  that.
  - ⚠️ **The download stops at `MAX_CARD_IMAGE_BYTES`**, through `ApplicationService#download`.
    The picture belongs to a page that the owner linked to, and the worker is a 512MB VM. A larger
    picture loses the thumbnail only.
  - ⚠️ **A body with no image content type goes through libvips before it goes up.** A host with no
    `Content-Type`, or a 200 that is an HTML error page, must not go up as a picture: the decode is
    the check.
  - **A card with no picture still renders**, thus each step here fails soft and the post never goes
    away with the image.
  - ⚠️ This is **not** `AtProto#upload_image_blob`, which asks the Contentful Images API for a
    smaller copy. `StandardSite` uses that one, because its pictures are always Contentful assets.
- **The body is plain text and not Markdown**, thus the facets come from the same string that the
  record holds and no code renders anything first. `Bluesky` marks a bare URL, an @mention, and a
  #hashtag.
  - ⚠️ **Each offset is in BYTES of the UTF-8 text, and not in characters.** One accented letter is
    1 character and 2 bytes, thus a character offset moves the highlight of each facet after it.
  - ⚠️ **A mention that the PDS cannot resolve is dropped.** A mention facet with no DID makes the
    record invalid, and the whole post then fails.
  - ⚠️ **A mention or a tag inside a link is not a facet.** `…/profile/@me.bsky.social` and
    `…/#section` would otherwise get two facets over one range, and a client renders that as a
    broken link. A tag does not start with a digit, as in the client of Bluesky: `#1` is a number.
- ⚠️ **It does not send `validate: false`**, and `StandardSite` does. The PDS knows the `app.bsky.*`
  lexicons, thus its own check finds a record with an error before that post reaches a feed. It does
  not know the `site.standard.*` lexicons.
- ⚠️ **`MAX_GRAPHEMES` is 300, and Bluesky counts GRAPHEMES.** `String#length` gives UTF-16 code
  units, thus it counts one emoji as 2 or more. `social_controller.js` counts the same way in the
  browser with `Intl.Segmenter`, and a spec pins `Bluesky::MAX_GRAPHEMES` to
  `SocialPresenter::BODY_LIMIT`.
- **`post!` raises at each failure**, on purpose, thus `BlueskyPostJob` does the work again. The
  record key is what makes that safe.

#### The standard.site card

⚠️ **A `site.standard.document` record alone gives no card.** The post must name that record in its
embed, and Bluesky then renders the enhanced card in place of the ordinary one.

- **`OpenGraph` reads the `at://` URIs from the `<link rel>` tags of the page**, and not from
  Contentful and not from a lookup of the entry. `web/source/partials/_head.html.erb` writes
  `site.standard.publication` on each page and `site.standard.document` on each published post.
  ⚠️ **A crawler of Bluesky runs no JavaScript, thus those tags must stay server-rendered.**
  ⚠️ The result is that this works for **any** site that publishes them, and not for this one only.
- **`AtProto#strong_ref` makes each ref.** ⚠️ A strongRef needs the **CID**, and an `at://` URI
  holds none. Thus the only way to make one is to read the record with `com.atproto.repo.getRecord`.
  The CID also changes at each write, thus **nothing caches a ref**: an old CID names a version that
  is gone.
- ⚠️ **A PDS answers `getRecord` for its OWN repos only.** `AtProto#service_for` gives the
  authenticated service for our own DID, and it resolves `did:plc` at `plc.directory`. Each other
  method gives nil, and the card is then the ordinary one.
- ⚠️ **The publication alone is not a card.** That tag is on each page of a site, and the document
  is the thing that names one article. Thus with no document `associated_refs` gives an empty list.
- **Each step falls back with no message, on purpose.** No tag, a record that this app cannot read,
  and a DID that it cannot resolve all give the ordinary card from the `og:` tags. An ordinary card
  is still a good card, and a failure here must never lose the post.

### Posting to Mastodon

`Mastodon#post!` sends one `POST /api/v1/statuses`. The connection, the registration, and the OAuth
round trip are in the same class; refer to **Connected apps**.

- ⚠️ **The URL goes in the TEXT here, and Bluesky puts it in an embed.** Mastodon renders a link
  inline and makes its own preview card from the `og:` tags of that page. Thus this class needs no
  card and no image upload, and `MastodonPostJob` reads no `OpenGraph` card for it. **This is the
  concrete reason that the Social media page keeps the link out of the body**: each network attaches one
  differently, thus the page holds the link beside the text and each service composes its own.
- ⚠️ **`Idempotency-Key` is what makes a retry safe**, and it is the Mastodon answer to the
  `putRecord` of Bluesky. The instance keeps that key and answers with the status that it made
  already. `MastodonPostJob` sends the **same key** that the controller made before it added the
  job, thus each attempt carries one key.
  ⚠️ **That window is approximately an hour, and the Sidekiq retries go on for 24.** Thus `post!`
  also keeps the URL of the status in Redis at `mastodon:status:<key>` for `STATUS_TTL`, and a
  later attempt of the same job returns it and posts nothing. The header covers the quick retries,
  and the Redis key covers the late ones.
- **Each post is `public` and `en`.** This blog has one author and one language.
- ⚠️ **This class needs no length check.** Mastodon counts a URL as **23** characters whatever its
  true length, and a default instance permits 500. The body of a draft is at most 300, which is the
  Bluesky limit, thus 300 + 2 newlines + 23 is 325 and a post always fits. An instance with a limit
  below that would refuse the post, and the job would then run again.
- **`post!` raises at each failure**, as `Bluesky#post!` does, thus `MastodonPostJob` does the
  work again.

### Posting to Threads

`Threads#post!` needs the **two steps** of Meta: it makes a media container, then it publishes that
container.

- ⚠️ **The URL is a `link_attachment`, and it is NOT in the text.** Meta then renders its own
  preview card, and the URL uses none of the 500 characters. **Mastodon is the opposite** and puts
  the link in the text, and Bluesky is a third form again, with an embed that holds an image blob.
  Those three are the reason that the Social media page keeps the link **beside** the body.
- ⚠️ **Meta gives NO idempotency header, and the container is the answer to that.** `#post!` keeps
  the id of the container in Redis at `threads:container:<key>`, and it deletes that key only
  **after** Meta publishes. Thus a failure between the two steps leaves the container for the retry,
  and that retry publishes the same container in place of a second post. Without this, each attempt
  would make one more container, and a person would get more than one post.
  - The TTL is 20 hours. ⚠️ Meta expires a container after 24 hours, thus a longer TTL would name a
    container that is gone.
- ⚠️ **It waits for the container before the publish**, with a poll of `CONTAINER_POLL_ATTEMPTS`
  reads at `CONTAINER_POLL_SECONDS`. A publish that comes too early gets `400 subcode 4279009`,
  which reads as a container that was never made. Meta processes a TEXT container as well. Three
  reads that fail in a row end the poll, and the retry of Sidekiq is the wait; the container stays
  in Redis, thus that retry costs no new container.
- ⚠️ **The id of a published post stays in Redis** at `threads:published:<key>` for `PUBLISHED_TTL`.
  Sidekiq redelivers a job whose process died between the publish and the acknowledgement, and
  that attempt answers with the id and makes no second post. Both TTLs are longer than the
  24-hour retry window, on purpose.
- **`MAX_CHARACTERS` is 500 and this class checks nothing.** The body of a draft is at most 300,
  which is the Bluesky limit, thus a post always fits.
- ⚠️ **`error_message` parses the body itself and does not use `parse_json`.** That helper returns
  nil for a response that failed **and** reports an upstream error, and this method already runs
  inside one.

### The spam quarantine

**Spam** (`/spam`) lists each message that Akismet flagged, the newest first, with **Not spam** and
**Delete forever**. `ContactMailJob` does not drop a flagged message: it stores it with
`SpamQuarantine`. **Not spam** enqueues that job again with `restored_from_spam`, which does not do
the check and which calls `Akismet#submit_ham`.

- **There is one Redis hash**, `contact:spam`, through `JsonHashStore`, and each field name is an
  id that the code makes. There is no key for each message, on purpose: no other code here reads the
  full keyspace, and this Redis also holds the Sidekiq queues, thus a `SCAN` would be the first one.
  ⚠️ The result is that
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
⚠️ `LocationPresenter#state_label` and `#state_variant` render the first state, and
`location_map_controller.js` renders each state after that. **Both read the same
`admin.location.state.*` keys**, through the `data-admin-i18n` attribute, thus the words cannot
become different. `location_map_controller.js` holds the `variant` of each state and no words, and
`spec/requests/admin/location_spec.rb` pins that the browser gets those same keys.

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
- **There is one Redis hash**, `maps:tracks`, through `JsonHashStore`, and each field name is the
  tileset id. The reason is the same as for the spam quarantine. A record holds the bounding box, both end points, the sport,
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
- **The name of a marker icon says what it marks** (`MARKER_ICONS`), and it is not the Maki id.
  ⚠️ The value of that constant is the **name of a translation** and not the words: `StaticMap.icon_options`
  and `.style_options` render the two dropdowns from `admin.course_maps.icons.*` and
  `admin.course_maps.styles.*`. The first icon for a sport comes from `GpxTrack::SPORT_ICONS`, whose
  fallback is running and not a neutral icon.
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
- **The body limit** (`lib/middleware/request_body_limit.rb`) answers 413 from `CONTENT_LENGTH`
  before rack-attack and before any code reads a body. Each path prefix has its own limit, and the
  default is small. Without it, the webhook path read a body of any size into memory two times
  before the signature check.
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
  There is also a `webhooks/ip` throttle, with a high limit: Contentful sends one webhook for each
  entry of a bulk publish and never sends a delivery again, thus the limit must stay far above a
  true burst. There is also a `contact/ip` throttle with a small scope (5 each hour). That is the one place
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

⚠️ **The specs use the Redis of `.env.test`, which is database 1 of the local Redis.** The specs
write and delete real keys with no namespace, and this includes `bluesky:credentials`,
`mastodon:credentials`, and `threads:credentials`. With the `REDIS_URL` of `.env`, each `rspec` run
disconnected the accounts that you connected in the admin on your own machine. dotenv reads
`.env.test` before `.env`, and CI sets `REDIS_URL` in the environment, which wins over both.
`spec/support/streamed_get.rb` stubs `HTTParty.get` for the code that reads a body through
`ApplicationService#download`: that method reads in fragments, thus a plain `and_return` gives it
nothing.

⚠️ **An admin spec asserts `I18n.t("admin.…")`, and never the words.** Each user-facing word of the
admin is in `config/locales/en.yml`, thus a change to the copy must break no spec. Refer to **The
admin UI**.

- A literal stays only where that literal is the thing that the spec proves: a path, a piece of
  markup, `<button`, a secret that must be absent, and the escaped `<script>` payload of the spam
  page.
- ⚠️ **A body assertion escapes the translation** (`ERB::Util.html_escape(I18n.t(…))`), because ERB
  escaped the apostrophe of "didn't". A `flash` assertion compares the raw string.
- `t_before(key, :placeholder)` in `spec/support/translation_helpers.rb` gives the words before an
  interpolation. Use it where the value — a date, a count — is behaviour that the spec must prove
  and the words around it are copy.
- ⚠️ **Never assert that a translation equals its own key.** Such a spec proves nothing and it puts
  the copy back in two files.

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
  `FONT_AWESOME_VERSION`, `WHOOP_REFERRAL_URL`, `ANTHROPIC_API_KEY` with
  `ANTHROPIC_DESCRIPTION_MODEL` and `ANTHROPIC_CONTACT_SUBJECT_MODEL` (the default of both is
  `claude-sonnet-5`), `PURPLEAIR_API_KEY`, `GOODSPEED_API_URL` (with no value the bay-conditions
  integration is off, and the app omits the sentence about the water temperature and the bay
  readings for a race day in SF), `LOCATION`, `TIME_ZONE`, `BLUESKY_PDS_URL` (⚠️ the handle and the
  app password of Bluesky are **not** environment variables: a person sets them on the Connected
  apps page of the admin, and the app stores them in Redis. ⚠️ **Mastodon has no environment
  variable at all**: the app registers itself on the instance that the owner names, and the same
  page is the only method to connect it. ⚠️ **The TrainerRoad calendar URL is not an environment
  variable either**: the same page is the only method to set it), `THREADS_APP_ID` and `THREADS_APP_SECRET` (the Threads app
  of the Meta dashboard. ⚠️ There is no redirect-URI variable: the callback URL comes from the
  request, and the dashboard must list `https://<your-admin-host>/connected-apps/threads/callback`.
  ⚠️ The *account* is connected on the admin page, and its token lives 60 days and cannot be renewed
  after it expires, thus `ThreadsTokenRefreshJob` needs the worker process to run), `BUGSNAG_API_KEY` (for production
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
  is trending"), `MAPBOX_USERNAME` and
  `MAPBOX_SECRET_TOKEN` (a token with `tilesets:write` and `tilesets:read`. If one of the two has no
  value, the Maps page says so and refuses each upload), `MAPBOX_ACCESS_TOKEN` (the ⚠️ **public**
  token: the server uses it to render when there is no secret token, and the map in the browser on
  the Location page needs it. With no value that page changes to a form for the coordinates),
  `MAPBOX_STYLE_URL` (the default style for a new track. Each track can use a different style, and
  the Location page ignores this value), `REDIS_POOL_SIZE` (the default is 10. Make it as large as
  the largest consumer, which is the concurrency of Sidekiq), the seven `TRENDING_*` values for the
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
