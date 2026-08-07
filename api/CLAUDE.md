# api/ — Kona widget API

Rails 8.1 API (Ruby 4.0.6) serving small embeddable **HTML fragments** ("widgets"), plus
structured-data endpoints and inbound webhooks, for the static `web/` site. Deployed to **fly.io**
as `kona-api` (`app` + `worker` processes), with the origin proxied behind **Cloudflare**.
Redis-backed caching, **no database**.

Minimal Rails: only ActiveModel + ActionController + ActionView are loaded (no ActiveRecord /
ActiveJob / ActionMailer / ActionCable). See the root [`CLAUDE.md`](../CLAUDE.md) for the web↔api
markup contract before changing any view, and for the comment-style conventions this app follows.

Routes split by namespace: `/widgets/*` (HTML fragments, reached through the web app's proxy),
`/api/*` (structured data, hit directly at the origin), `/webhooks/*` (inbound, hit directly by
the sending service).

## Endpoints

All `/widgets/*` responses are HTML fragments (`layout false`). Edge TTL = how long the edge serves
a cached copy before revalidating.

| Method | Path | Returns | Edge TTL |
|---|---|---|---|
| GET | `/up` | health check | — |
| GET | `/widgets/activity-stats` | Intervals.icu totals | 5 min |
| GET | `/widgets/weather/current` | weather/AQI/pollen | 5 min |
| GET | `/widgets/events/upcoming` | upcoming races; the featured event has inline race-day weather | 1 hr |
| GET | `/widgets/articles/trending[/:id]` | "hot today" articles; `:id` excludes one Contentful id, so an article page can drop itself | 1 hr |
| GET | `/widgets/articles/related/:id` | "You May Also Like", from precomputed Voyage embeddings | 1 hr |
| GET | `/widgets/whoop` | sleep/recovery/strain | 5 min |
| GET | `/widgets/plausible/pageviews/:id` | pageview count by Contentful id | 5 min |
| POST | `/api/location` | sets Redis `location:current` + enqueues `LocationSyncJob` | — |
| POST | `/api/contact` | drops honeypot hits + enqueues `ContactMailJob`; JSON → 204/422, HTML → 303 | — |
| POST | `/api/build` | enqueues `SiteBuildJob`; 202, or 429 inside the 60s dedupe lock | — |
| POST | `/api/icons` | resolves the web build's Font Awesome allowlist to SVGs | — |
| GET | `/api/standard-site` | `{did, publication_uri}` for the build's verification markup | 1 hr |
| POST | `/webhooks/contentful` | enqueues PDS sync, embedding, asset-mirror, and site-build jobs; 204 | — |
| POST | `/webhooks/whoop` | enqueues `WhoopWebhookJob`; 200 `{ok: true}` | — |
| GET | `/whoop/auth`, `/whoop/callback` | Whoop OAuth (authorize is owner-gated) | — |
| GET | `/login`, `/auth/google_oauth2/callback`; POST `/logout` | owner session | — |
| — | `/sidekiq` | job dashboard (owner-session gated) | — |
| GET | `/` | 301 → main site | — |

## Architecture

### Controllers

One namespace per kind of endpoint, all inheriting `ActionController::Base` directly (not
`ApplicationController`) to skip the modern-browser gate:

- `widgets/` — `Widgets::BaseController` (`layout false`, includes `LiveWidget`). Widget actions
  fetch via a service, call `cache_widget(ttl:)`, then render an ERB fragment. Use `render_empty`
  when data is unavailable — the site's live-update controller removes the placeholder, so prefer
  it over raising.
- `api/` — structured data under `Api::BaseController`. `ContactController` is the one
  browser-reachable write (through the web proxy).
- `webhooks/` — one controller per sending service under `Webhooks::BaseController`.

**Auth** — `Widgets::BaseController` and `Api::BaseController` require the `API_TOKEN` bearer
(`TokenAuthentication`) via a global `before_action`, so the widget origin is closed to direct hits
(a cheap 401 before any work). A new widget endpoint is gated automatically by inheriting the base
controller. `standard-site` skips it (public, build-time fetched). Webhook controllers don't use
the bearer at all — senders can't carry our token, so each authenticates with its service's own
HMAC scheme.

**Owner auth** — `/whoop/auth` and `/sidekiq` are gated by a **Google OAuth** sign-in restricted to
a single identity, not the bearer. `SessionsController` runs the OmniAuth flow and accepts a login
only when the verified email equals `OWNER_EMAIL` (and the `hd` domain check passes), then stores
`owner_email` in the signed cookie session. The `Authentication` concern gates the Whoop
controller; a small Rack guard in the Sidekiq initializer gates the mounted `Sidekiq::Web`.

### Services

`app/services/`, base `ApplicationService`: one per external API — Intervals.icu, Apple WeatherKit
(ES256 JWT), Google Maps / Air Quality / Pollen, PurpleAir, Whoop (OAuth2), TrainerRoad (iCal),
Contentful, Plausible, Font Awesome, Goodspeed, Akismet, Resend, Turnstile, Voyage (`Embeddings`),
`StandardSite`, `AssetMirror`. Read-through Redis cache via `cached_json(key, expires_in:)`;
HTTParty with retries; `DeepOstruct` for dot-access.

⚠️ **Plausible is rate-limited to 600 calls/hour**, and `cached_json` caps each distinct query body
at one call per its 5-minute TTL — so what matters is the number of *distinct queries*, not
requests. `Plausible#pageviews_by_path` is therefore **one site-wide query** shared by
`TrendingArticles` and the per-article pageviews widget; asking per article would mint a key per
article and scale the ceiling with the corpus, over the limit. **Don't reintroduce a per-article
query, and redo the math before shortening either TTL.**

**Failure modes worth knowing:**

- Most services degrade — a failure collapses the widget rather than raising.
- `Akismet` fails **closed** when configured (an outage raises so the intake job retries) and open
  only when unconfigured. `Turnstile` fails open.
- `AssetMirror` **raises**, so Sidekiq retries — a silently skipped asset surfaces later as a
  broken image on a live page.

### The R2 image mirror

`AssetMirror` copies every published Contentful **image** asset into an R2 bucket, and the `web/`
build rewrites asset URLs onto that bucket's custom domain. ⚠️ **This is a cross-app data contract
and neither side validates the other** — full write-up in the root [`CLAUDE.md`](../CLAUDE.md).

- **Publish only.** ⚠️ Unpublish and delete deliberately don't remove the object: the web build
  reads Contentful with a **preview** token, so an unpublished asset is still referenced by built
  pages. Keys are content-addressed, so objects are immutable and nothing needs invalidating.
- ⚠️ **The download uses `Net::HTTP#read_body`, not HTTParty — don't "fix" it to match the house
  style.** These originals reach 38MB and the worker is a **512MB** VM at **concurrency 5**.
  Buffering whole files OOM-killed it during the first backfill, and a hard kill isn't a failure
  Sidekiq can retry, so the in-flight jobs vanished silently — 13 assets never mirrored, surfacing
  only as 404s on live pages. HTTParty doesn't solve it even with `stream_body: true`: measured at
  +52.3MB peak RSS against +1.2MB for the streaming loop. The Tempfile matters for the same reason
  — it lets the S3 client upload from disk rather than a second copy in memory. If the asset
  library grows many more large originals, bump the VM before raising concurrency.
- **`rake assets:backfill`** enqueues a job per asset, each skipping one already in the bucket (one
  HEAD, no transfer), so it's cheap to re-run and doubles as the reconciliation net for webhook
  deliveries Contentful never retries. `DRY_RUN=1` reports the count. ⚠️ Run it to completion
  **before** `IMAGE_HOST` is set on the web side.
- No-ops entirely when the `R2_*` vars are absent, so dev/CI stay inert.

### Webhooks

`Webhooks::ContentfulController` receives publish/unpublish/delete events (HMAC-verified via
`ContentfulRequestVerification`) and **only enqueues jobs**, returning 204; the work runs on the
Sidekiq worker. On every publish it enqueues the standard.site sync, the article embedding, the R2
asset mirror, and **`SiteBuildJob`** to rebuild the web site. Scope the Contentful webhook to
**Entry + Asset** publish/unpublish/delete (so image-only changes rebuild too) and **not**
auto-save. ⚠️ Contentful does **not** retry deliveries — `rake standard_site:backfill` and
`rake assets:backfill` are the reconciliation paths.

`Webhooks::WhoopController` receives Whoop v2 webhooks, verified with Whoop's HMAC scheme
(`WhoopRequestVerification`: signed with `WHOOP_CLIENT_SECRET`, base64 HMAC over timestamp + raw
body, ±5 min skew) plus a payload `user_id` check against the authenticated athlete (Redis-cached
for a day; foreign users get 403 so Whoop stops retrying). It enqueues and responds 200 within
Whoop's ~1s expectation. Register the URL with **Model Version V2** in the Whoop dashboard.

Processing (`WhoopWebhookProcessor`) writes the custom wellness fields `WhoopStrain` /
`WhoopSleepPerformance` / `WhoopRecovery` and the activity field `WhoopWorkoutStrain` — ⚠️ all four
must exist in Intervals.icu → Settings → Custom Fields, or a 422 is logged and skipped — then
enqueues a separate `ActivityDescriptionJob`. The split is deliberate: if the Whoop integration
ever goes away, the metric sync disappears entirely while descriptions keep working, losing only
the 🔥 line.

### Background jobs

Native **Sidekiq** (`Sidekiq::Job`, not ActiveJob), in `app/jobs/`, inheriting `ApplicationJob` —
a plain superclass holding the shared `retry_for: 24.hours` (normal backoff, then Dead-set once 24
hours have passed since the first failure). Every job takes plain-string args and is idempotent, so
that shared window is safe.

| Job | What |
|---|---|
| `StandardSiteSyncJob(operation, entry_id)` | standard.site PDS sync |
| `AssetSyncJob(asset_id)` | mirrors one image asset into R2 (⚠️ raises rather than degrading) |
| `ArticleEmbeddingJob(operation, entry_id)` | keeps an article's Voyage embedding in sync |
| `SiteBuildJob(event_type)` | fires a GitHub `repository_dispatch` to rebuild the web site |
| `WhoopWebhookJob(event_type, resource_id, trace_id)` | syncs Whoop metrics to Intervals.icu |
| `ActivityDescriptionJob(activity_id, whoop_strain = nil)` | (re)generates an activity's Strava description |
| `LocationSyncJob(latitude, longitude)` | propagates the current location to Intervals.icu |
| `ContactMailJob(name, email, message, context)` | contact intake: Akismet + compose |
| `ContactDeliveryJob(payload)` | the one retryable *delivery* unit — sends via Resend |

- **`SiteBuildJob`** has two callers with one event type each — the Contentful webhook
  (`contentful-publish`) and `POST /api/build` (`api-build`). They build identically and differ
  only so the deploy's Slack notification can name the trigger. ⚠️ **Both event types must stay
  listed in that workflow's `repository_dispatch.types`** — GitHub accepts a dispatch for an
  unlisted type with a 204 and silently runs nothing. The event type is always a caller-supplied
  constant, never a request parameter. No-ops when `GITHUB_DISPATCH_TOKEN`/`GITHUB_REPOSITORY` are
  unset.
- **`ActivityDescriptionJob`** is **source-agnostic**: emoji stat lines (power, heat, Whoop strain,
  water temp) plus two Anthropic-generated lines (a planned-workout summary matched against the
  TrainerRoad calendar, and a weather sentence — prompts in `app/prompts/`, skipped without
  `ANTHROPIC_API_KEY`), preserving any user-written prose above the stat block. Deduped per
  activity by a Redis lock.
- **The contact form is a two-job pipeline** so a Resend failure retries only the send. Akismet
  fails closed, so an outage retries the *intake* job rather than delivering an unchecked message;
  `ContactSubject` (a Claude-generated subject line) fails soft.

Config in `config/initializers/sidekiq.rb` and `config/sidekiq.yml`. Sidekiq runs as a dedicated
**`worker` fly process**; a worker must be running to drain the queue (locally: `bundle exec
sidekiq`).

### Views, helpers, presenters

Views (`app/views/widgets/`) render raw HTML fragments. **Helpers** (`app/helpers/`) are pure
formatting/selection functions — every method takes the data it works on as explicit arguments;
none read controller ivars. Request state lives in **presenters** (`app/presenters/`):
`WeatherSummaryPresenter` (the weather widget's prose + business rules), `EventWeatherPresenter`,
`UpcomingRacesPresenter`, `WhoopPresenter`. Presenters take their data as constructor kwargs. When
a controller body needs a helper, it calls it through the `helpers` proxy rather than `include`-ing
the module.

### Caching

`app/controllers/concerns/live_widget.rb`. `cache_widget(ttl:)` sets:

- Browser: `Cache-Control: public, max-age=0, stale-while-revalidate=86400`
- Edge: `CDN-Cache-Control: public, max-age=<ttl>, stale-while-revalidate=3600, stale-if-error=86400`

RFC 9213 — Cloudflare honors `CDN-Cache-Control`, browsers ignore it, which is what lets the edge
TTL differ from the browser's `max-age=0`.

⚠️ **Never express the edge policy as `s-maxage`** — its presence disables `stale-while-revalidate`
and `stale-if-error` (RFC 9111 §4.2.4), which is what keeps widgets rendering through a fly outage.

⚠️ **Only emit this on successful, cacheable responses.** An error must never be pinned at the edge.

⚠️ **Editing a `cache_widget(ttl:)` does not reach copies already at the edge — purge, or the
change won't land.** A cached fragment keeps the `CDN-Cache-Control` it was *stored* with, so PoPs
serve the old body under the old policy until it expires on its own terms. Shortening the pageviews
TTL from 1 h to 5 min once left copies live under the previous `stale-while-revalidate=86400` — a
view count up to **25 hours** stale, which reads as the counter running backwards. Same for a
markup change.

**Purging is the one piece of this policy the app does not author.** The widgets that render
Contentful content are tagged `Cache-Tag: site` by a **zone Cache Response Rule** matching
`/widgets/articles/*` and `/widgets/events/*` on this host, so the web deploy's tag purge evicts
them when content is republished. Nothing here or in the web proxy sets that tag. ⚠️ **Moving a
widget out of those namespaces — or adding a Contentful-backed widget under a new one — silently
stops the purge**, and no code change can fix it; it needs a dashboard edit. Full reasoning, plus
the manual `widgets` tag, in the root [`CLAUDE.md`](../CLAUDE.md).

### Errors and abuse mitigation

- **Bugsnag** (`config/initializers/bugsnag.rb`) — its railtie auto-inserts the Rack middleware and
  hooks ActionDispatch, so unhandled exceptions are reported even though errors render as plain
  text. `notify_release_stages` is production-only and `BUGSNAG_API_KEY` is unset locally/in CI, so
  it's a no-op outside production.
- **Errors render as plain text** via `lib/plain_text_exceptions.rb`. Unmatched paths hit the
  trailing `match "*unmatched"` route → `ApplicationController#route_not_found`, which keeps
  scanner probes to a single clean `status=404` lograge line rather than an exception backtrace.
  ⚠️ That catch-all **must stay the last route** — enforced by `spec/routing/routes_guard_spec.rb`.
- **rack-attack** (`config/initializers/rack_attack.rb`) blocklists probe paths (a flat 403 by
  **path pattern**, before routing) and throttles requests **to paths outside the known route
  prefixes**, keyed on `Request#client_ip` (`CF-Connecting-IP` → `Fly-Client-IP` → `req.ip`).
  ⚠️ **The blocklist must stay IP-agnostic — never ban by IP.** Some probe paths are reachable
  through the public `/widgets/*` proxy, and all legitimate widget traffic shares that proxy's
  egress IPs, so an IP ban would 403 every visitor's widgets at once (this once took the site
  down). Same reason: no blanket per-IP throttle.
  ⚠️ **If you add a top-level route, add its prefix to `RACK_ATTACK_KNOWN_PREFIXES`** or it will be
  rate-limited — a missing prefix fails `spec/routing/routes_guard_spec.rb`.
  There's also a scoped `contact/ip` throttle (5/hour), the one place a per-visitor IP is safe: it
  uses the proxy-forwarded `X-Kona-Client-IP` (the real visitor, not the shared egress) and it's a
  throttle, never a ban.
- **Redis** — global `$redis` from `config/initializers/redis.rb`, via `REDIS_URL`. The same Redis
  backs the Sidekiq queues.

## Commands

```bash
bin/dev                                                          # local server (or bin/setup)
bundle exec sidekiq -C config/sidekiq.yml                        # local worker
bundle exec rspec spec/requests/widgets/activity_stats_spec.rb   # single spec
bundle exec rspec                                                # full suite
bin/ci                                                           # setup + suite + security scan
bundle exec brakeman -q --no-pager
bundle exec bundle-audit check --update
fly deploy                                                       # app + worker
fly console

# Trigger a web rebuild (needs a running worker). ⚠️ Against production this ships a real deploy.
curl -i -X POST -H "Authorization: Bearer $API_TOKEN" "$KONA_API_URL/api/build"
```

No Rubocop or linter is configured. CI runs Brakeman + bundler-audit, and the deploy job **won't
run unless both pass**. If Brakeman flags a verified false positive, add a checked-in
`config/brakeman.ignore` rather than weakening the code.

## Testing

RSpec request specs in `spec/requests/`, plus `spec/services/` and `spec/presenters/`. No DB or
fixtures — stub services with
`allow_any_instance_of(SomeService).to receive(:method).and_return(...)`. Specs assert the rendered
markup **and** the cache headers.

## Environment variables

Names only — see `.env.example`; never commit values. Production values are fly.io secrets (plus
Rails `config/credentials.yml.enc` + `master.key`).

- **Required**: `REDIS_URL`, `ICU_ATHLETE_ID`, `ICU_API_KEY`, `FONT_AWESOME_API_TOKEN`,
  `WHOOP_CLIENT_ID`, `WHOOP_CLIENT_SECRET`, `WHOOP_REDIRECT_URI`, `GOOGLE_OAUTH_CLIENT_ID`,
  `GOOGLE_OAUTH_CLIENT_SECRET`, `OWNER_EMAIL`, `GOOGLE_API_KEY`, `API_TOKEN` (must match the web
  app's), `WEATHERKIT_KEY_ID`, `WEATHERKIT_TEAM_ID`, `WEATHERKIT_SERVICE_ID`,
  `WEATHERKIT_PRIVATE_KEY` (base64 .p8), `CONTENTFUL_SPACE`, `CONTENTFUL_TOKEN`,
  `CONTENTFUL_WEBHOOK_SECRET` (64-char HMAC secret), `SITE_URL`, `RESEND_API_KEY`,
  `CONTACT_FROM_ADDRESS` (a sender on a domain verified in Resend — it needs only SPF/DKIM, so it
  coexists with a Google Workspace mailbox on the same domain), `CONTACT_TO_ADDRESS`.
- **Optional**: `AKISMET_API_KEY` (unset = off, submissions delivered unchecked; set = fails
  closed), `TURNSTILE_SECRET` (pair with the web app's `TURNSTILE_SITE_KEY`, both or neither),
  `FONT_AWESOME_VERSION`, `WHOOP_REFERRAL_URL`, `TRAINERROAD_CALENDAR_URL`, `ANTHROPIC_API_KEY` +
  `ANTHROPIC_DESCRIPTION_MODEL` / `ANTHROPIC_CONTACT_SUBJECT_MODEL` (both default
  `claude-sonnet-5`), `PURPLEAIR_API_KEY`, `LOCATION`, `TIME_ZONE`, `BLUESKY_HANDLE`,
  `BLUESKY_APP_PASSWORD`, `BLUESKY_PDS_URL`, `BUGSNAG_API_KEY` (production only), `ALLOWED_HOSTS`
  (comma-separated `Host` allowlist; production only, unset = all hosts accepted, so it's safe to
  deploy before setting it; `/up` is always exempt), `R2_ACCOUNT_ID` + `R2_ACCESS_KEY_ID` +
  `R2_SECRET_ACCESS_KEY` + `R2_BUCKET` (⚠️ must be the bucket behind the web app's `IMAGE_HOST`;
  nothing validates that, and a mismatch 404s every image), `GITHUB_DISPATCH_TOKEN` +
  `GITHUB_REPOSITORY` (a fine-grained PAT with **Contents: Read and write**, plus the `owner/repo`
  slug), `PLAUSIBLE_API_KEY` + `PLAUSIBLE_SITE_ID` (⚠️ with either unset the pageviews widget
  collapses and `TrendingArticles` silently degrades to recency order — an INFO log is the only
  sign, and the result looks exactly like "working, nothing trending"), `VOYAGE_API_KEY` (unset =
  no embeddings, so the related-articles widget collapses), `REDIS_POOL_SIZE` (default 10; size it
  to the widest consumer, which is Sidekiq's concurrency), and the four `TRENDING_*` ranking knobs
  (see `.env.example`; they feed the ranking's cache key, so retuning one invalidates it).

## Conventions & gates

- **Before committing/deploying** (non-negotiable): `bundle exec rspec` passes.
- Keep widget markup in sync with the matching `web/` placeholder (root `CLAUDE.md`).
- Font Awesome icons are fetched on demand by family/style/id and cached per version in Redis —
  `icon_svg('classic', 'solid', 'eye')`. No allowlist needed here; any id a view references is
  fetched. The integration lives **only** in this app — `web/` POSTs its own allowlist to
  `POST /api/icons`, so a new web icon needs no api change. ⚠️ That endpoint requests icons in
  small batches so a cold cache can't blow the per-request `rack-timeout`; don't change it to
  resolve the whole allowlist in one request.

### Permissions

- Autonomous: read files, single-file `rspec`, local `bin/dev`.
- Ask first: `fly deploy`, secret changes, anything that flushes Redis, `git push`/commit, package
  installs.
