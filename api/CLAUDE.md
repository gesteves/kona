# api/ — Kona widget API

Rails 8.1 API (Ruby 4.0.6) that serves small embeddable **HTML fragments** ("widgets")
— plus structured-data endpoints and inbound webhooks — for the static `web/` site.
Deployed to **fly.io** as `kona-api`, with the origin proxied behind **Cloudflare** — so
`Fly-Client-IP` is a Cloudflare PoP, not the visitor (see **Abuse mitigation** below and the
root [`CLAUDE.md`](../CLAUDE.md)). Routes are split by namespace: `/widgets/*` (HTML
fragments, reached through the web app's same-origin proxy), `/api/*` (structured
data, hit directly at the origin), and `/webhooks/*` (inbound webhooks, hit directly by
the sending service). Redis-backed caching, **no database**.

Minimal Rails: only ActiveModel + ActionController + ActionView are loaded (no
ActiveRecord / ActiveJob / ActionMailer / ActionCable). See the root
[`CLAUDE.md`](../CLAUDE.md) for the web↔api markup contract before changing any view.

## Endpoints

All `/widgets/*` responses are HTML fragments (`layout false`) with the cache
headers below. Edge TTL = how long the edge serves a cached copy before revalidating.

| Method | Path | Action | Returns | Edge TTL |
|---|---|---|---|---|
| GET | `/up` | `rails/health#show` | health check | — |
| GET | `/widgets/activity-stats` | `widgets/activity_stats#show` | HTML (Intervals.icu totals) | 5 min |
| GET | `/widgets/weather/current` | `widgets/weather#current` | HTML (weather/AQI/pollen) | 5 min |
| GET | `/widgets/events/upcoming` | `widgets/events#upcoming` | HTML (upcoming races; featured event has inline race-day weather) | 1 hr |
| GET | `/widgets/articles/trending` | `widgets/articles#trending` | HTML ("hot today" articles — Plausible pageviews over a flat 48h window vs. each post's own baseline, recomputed hourly) | 1 hr |
| GET | `/widgets/articles/trending/:id` | `widgets/articles#trending_excluding` | HTML (trending minus one Contentful id — an article page passes its own id so it isn't listed) | 1 hr |
| GET | `/widgets/articles/related/:id` | `widgets/articles#related` | HTML ("You May Also Like" — articles semantically related to `:id`, ranked from precomputed Voyage embeddings) | 1 hr |
| GET | `/widgets/whoop` | `widgets/whoop#show` | HTML (sleep/recovery/strain) | 5 min |
| GET | `/widgets/plausible/pageviews/:id` | `widgets/plausible#pageviews` | HTML (pageview count by Contentful id) | 1 hr |
| POST | `/api/location` | `api/location#create` | sets Redis `location:current` + enqueues a `LocationSyncJob` (bearer-token gated) | — |
| POST | `/api/contact` | `api/contact#create` | drops honeypot hits + enqueues a `ContactMailJob` (Akismet spam-check → Cloudflare email to the owner, Reply-To = sender); JSON → 204/422, HTML → 303 to `/contact/success` (bearer-token gated, browser-reachable via the web proxy) | — |
| POST | `/webhooks/contentful` | `webhooks/contentful#create` | enqueues a standard.site PDS sync job on publish/unpublish/delete (HMAC-gated); 204 | — |
| POST | `/webhooks/whoop` | `webhooks/whoop#create` | enqueues a `WhoopWebhookJob` syncing strain/sleep/recovery to Intervals.icu wellness + regenerating the matched activity's description (HMAC-gated, user-verified); 200 `{ok: true}` | — |
| GET | `/api/standard-site` | `api/standard_site#show` | JSON `{did, publication_uri}` for the web build's verification markup | 1 hr |
| POST | `/api/icons` | `api/icons#create` | JSON `{family: {style: [{id, svg}]}}` — resolves the web build's posted Font Awesome allowlist to SVGs (bearer-token gated) | — |
| GET | `/whoop/auth` | `whoop_oauth#authorize` | redirect (owner-session gated) | — |
| GET | `/whoop/callback` | `whoop_oauth#callback` | OAuth token exchange | — |
| GET | `/login` | `sessions#new` | owner sign-in page (Google button) | — |
| GET | `/auth/google_oauth2/callback` | `sessions#create` | Google OAuth callback → sets owner session | — |
| POST | `/logout` | `sessions#destroy` | clears the owner session | — |
| — | `/sidekiq` | `Sidekiq::Web` (mounted) | background-job dashboard (owner-session gated) | — |
| GET | `/` | redirect | 301 → main site | — |

## Architecture

- **Controllers** (`app/controllers/`), one namespace per kind of endpoint:
  - `widgets/` — HTML-only widget endpoints. `Widgets::BaseController` (`layout false`,
    includes the `LiveWidget` concern); widget controllers fetch via a service, call
    `cache_widget(ttl:)`, then render an ERB fragment. Use `render_empty` (blank body)
    when data is unavailable — the site's `live-update` controller removes the placeholder
    (collapsing the widget) on an empty response, so prefer it over raising.
  - `api/` — structured-data endpoints (accept or return data, not markup):
    `Api::LocationController`, `Api::StandardSiteController`, `Api::ContactController` under
    `Api::BaseController`. `ContactController` is the one browser-reachable write (through the
    web proxy): it drops honeypot hits, validates (incl. length caps), verifies **Turnstile** on
    the JSON path (skipped for the no-JS HTML path — the widget needs JS), and enqueues
    `ContactMailJob` (`Akismet` spam-check → `Resend` email to the owner, with a Sender-details
    block from the forwarded IP/geo/UA). It answers by `Accept` — JSON (`fetch`) → 204/422, HTML
    (no-JS native POST) → 303 to the site's Thank-You page. See the root `CLAUDE.md` contact
    contract for the full defense-layer rundown.
  - `webhooks/` — inbound webhooks, one controller per sending service under
    `Webhooks::BaseController` (currently `Webhooks::ContentfulController`).
- **Auth** — `Widgets::BaseController` and `Api::BaseController` require the `API_TOKEN`
  bearer (`TokenAuthentication` concern) via a global `before_action`; the web app's Worker
  proxy injects it on widget requests, so the widget origin is closed to direct/public hits
  (cheap 401 before any work). `POST /api/icons` keeps the bearer (the web build sends it) —
  a novel icon id triggers a paid upstream Font Awesome call, so scanners get a cheap 401
  first. `standard-site` skips it (public, build-time fetched directly
  via `KONA_API_URL`). Webhook controllers don't use the bearer at all — senders can't carry
  our token, so each authenticates with its service's own scheme (Contentful: HMAC request
  verification). A new widget endpoint is gated automatically by inheriting
  `Widgets::BaseController`.
- **Owner auth** — the owner-only surfaces (`/whoop/auth` and the `/sidekiq` UI) are gated by a
  **Google OAuth** sign-in restricted to a single identity, **not** the `API_TOKEN` bearer.
  `SessionsController` runs the OmniAuth (`omniauth-google-oauth2`) flow and accepts a login only
  when the verified email equals `OWNER_EMAIL` (and the provider's `hd` domain check passes),
  then stores `owner_email` in the signed cookie session. The `Authentication` concern
  (`require_owner!`) gates the Whoop controller; a small Rack guard in the Sidekiq initializer
  gates the mounted `Sidekiq::Web` on the same session (unauthenticated → redirect to `/login`).
- **Services** (`app/services/`, base `ApplicationService`): one per external API —
  Intervals.icu, Apple WeatherKit (ES256 JWT), Google Maps / Air Quality / Pollen,
  PurpleAir, Whoop (OAuth2), TrainerRoad (iCal), Contentful (events/articles),
  Plausible, Font Awesome, Goodspeed (bay conditions), `Akismet` (contact-form spam check —
  plain-text `true`/`false`; fails **closed** when configured — raises so the intake job retries —
  and open only when unconfigured), `Resend` (the contact form's email delivery — an HTTPS
  API, so it works from fly, which blocks outbound SMTP), `Turnstile` (contact-form bot-challenge
  siteverify — verified in the request path since tokens are single-use/300s; fails open),
  `StandardSite` (publishes the
  blog to the AT Protocol / Bluesky PDS as standard.site records — webhook-driven, plus
  the `standard_site:backfill` rake task in `lib/tasks/`). Read-through Redis cache via
  `cached_json(key, expires_in:)`; HTTParty with retries; `DeepOstruct` for dot-access.
- **Webhooks**: `Webhooks::ContentfulController#create` receives Contentful publish/
  unpublish/delete events and keeps the standard.site PDS records in sync. Verified with
  Contentful's HMAC request-verification scheme (`ContentfulRequestVerification` concern,
  `CONTENTFUL_WEBHOOK_SECRET`). The request only **enqueues jobs** and returns 204; the work runs
  on the Sidekiq worker (Sidekiq retries on failure). On every publish/unpublish/delete it also
  enqueues **`SiteBuildJob`**, which fires a GitHub `repository_dispatch` to rebuild the web site
  (this replaces the old Contentful→host build hook — the `.github/workflows/web.yml` "Web"
  workflow builds from it; scope the Contentful webhook to **Entry + Asset** publish/unpublish/
  delete so image-only changes rebuild too, and **not** auto-save). Contentful
  does **not** retry deliveries, so `rake standard_site:backfill` remains the broader
  reconciliation/recovery path. Operations log at info level (`standard.site: …`).
  `Webhooks::WhoopController#create` receives Whoop v2 webhooks (`workout.updated`,
  `sleep.updated`, `recovery.updated`, …), verified with Whoop's HMAC scheme
  (`WhoopRequestVerification` concern — signed with `WHOOP_CLIENT_SECRET`, base64 HMAC over
  timestamp + raw body, ±5 min skew) and a payload `user_id` check against the authenticated
  athlete (Redis-cached for a day; foreign users get 403 so Whoop stops retrying). The
  request enqueues a `WhoopWebhookJob` and responds 200 `{ok: true}` (Whoop expects a 2xx
  within ~1s and retries on failure). Register the webhook URL with **Model Version V2** in
  the Whoop developer dashboard. Processing (`WhoopWebhookProcessor`) writes the custom
  wellness fields `WhoopStrain` / `WhoopSleepPerformance` / `WhoopRecovery` and the activity
  field `WhoopWorkoutStrain` (all four must exist in Intervals.icu → Settings → Custom
  Fields — a 422 is logged and skipped, not retried), then enqueues a separate
  `ActivityDescriptionJob` (below) to regenerate the matched activity's description. The
  metric sync and the description are deliberately split: if the Whoop integration ever goes
  away, "sync Whoop metrics to Intervals.icu" disappears entirely, while "write activity
  descriptions" keeps working (triggered by another source) and simply loses its 🔥 line.
- **Background jobs** — native **Sidekiq** (`Sidekiq::Job`, not ActiveJob — ActiveJob stays
  disabled in `application.rb`). Jobs live in `app/jobs/` and inherit from `ApplicationJob` (a
  plain `Sidekiq::Job` superclass holding the shared `retry_for: 24.hours` — Sidekiq retries with
  its normal backoff, then Dead-sets a job once 24 hours have elapsed since the first failure);
  `StandardSiteSyncJob(operation,
  entry_id)` runs the standard.site sync (webhook- and backfill-driven),
  `SiteBuildJob()` fires a GitHub `repository_dispatch` (`contentful-publish`) to rebuild + redeploy
  the **web** site (the `.github/workflows/web.yml` "Web" workflow listens for it) — enqueued by the
  Contentful webhook on every publish/unpublish/delete so the static build picks up the change;
  no-ops when `GITHUB_DISPATCH_TOKEN`/`GITHUB_REPOSITORY` are unset, and
  `ArticleEmbeddingJob(operation, entry_id)` keeps an article's Voyage embedding (the
  `embeddings:article:<id>` Redis key) in sync for the related-articles widget — `"embed"` on
  publish, `"delete"` on unpublish/delete (webhook-driven, plus the `embeddings:backfill` rake
  task), `WhoopWebhookJob(event_type, resource_id, trace_id)` syncs a Whoop webhook's
  metrics to Intervals.icu wellness/activity fields (see **Webhooks** above), and
  `ActivityDescriptionJob(activity_id, whoop_strain = nil)` (re)generates an activity's
  Strava description via `ActivityDescription::Generator` / `Composer` / `Llm` — emoji stat
  lines (power, heat, Whoop strain, water temp) plus two
  Anthropic-generated lines (planned-workout summary matched against the TrainerRoad
  calendar, weather sentence — prompts in `app/prompts/`, skipped when `ANTHROPIC_API_KEY` is
  unset), preserving any user-written prose above the stat block, deduped per activity by a
  Redis lock (`whoop:description_lock:*`). It's **source-agnostic**: the Whoop workout path
  enqueues it today (passing the matched workout's strain for the 🔥 line), but it's
  re-triggerable by any future webhook with no strain, losing only that line. Finally,
  `LocationSyncJob(latitude, longitude)` propagates the current location to Intervals.icu
  (enqueued by `POST /api/location`): via `LocationSync` / `LocationContext` it reverse-geocodes
  the coordinates (`GoogleMaps`), then updates the athlete profile (city/state/country/timezone)
  and replaces the weather config with a single current-location forecast — each write skipped
  when Intervals.icu already matches, and the just-written timezone primed into the
  `intervals.icu:timezone:*` cache. The contact form is a **two-job pipeline** so a Resend
  failure retries only the send: `ContactMailJob(name, email, message, context)` (enqueued by
  `POST /api/contact`) is the intake — it runs the `Akismet` spam-check off the request path (a
  spam verdict is logged and dropped), then for a clean submission composes the email (a
  Sender-details block from the forwarded IP/geo/UA `context`, plus a **Claude-generated subject
  line** via `ContactSubject`, a structured-output Anthropic call mirroring `ActivityDescription::Llm`
  that fails soft to a static subject) and enqueues `ContactDeliveryJob(payload)`, which is the
  sole retryable *delivery* unit — it just sends the finished email via `Resend` (Reply-To = the
  sender). The split is deliberate: **`Akismet` fails closed** — when configured but unreachable
  or without a clean verdict it **raises**, so the intake job retries (never delivering a message
  that wasn't spam-checked; exhausted retries park it in the Dead set rather than let spam
  through). `ContactSubject` fails soft, and `Akismet` returns ham only when unconfigured, so on a
  normal run each runs once; only `Resend` re-runs on a delivery retry. Args are plain strings + a
  string-keyed hash and every operation is idempotent, so the shared 24-hour retry window is safe. Config in `config/initializers/sidekiq.rb` (Redis = `REDIS_URL`, web UI guard) and
  `config/sidekiq.yml` (concurrency). The **`/sidekiq` web UI** is mounted in `routes.rb` and
  gated by the owner session (Google OAuth — see **Owner auth** above), shared with `/whoop/auth`.
  Sidekiq runs as a dedicated **`worker` fly process** (see fly.toml); a worker must be running
  to drain the queue (locally: `bundle exec sidekiq`).
- **Views** (`app/views/widgets/`) render raw HTML fragments. **Helpers** (`app/helpers/`,
  originally ported from the web app) are pure formatting/selection functions — every method
  takes the data it works on as explicit arguments; none read controller ivars. Request state
  lives in **presenters** (`app/presenters/`): `WeatherSummaryPresenter` (the weather widget's
  prose + business rules; the view reads everything through `@summary`), `EventWeatherPresenter`
  (per-event race-day weather), and `WhoopPresenter` (scores/labels/heading). Presenters take
  their data as constructor kwargs and pass it to the helper functions they compose. When a
  controller body needs a helper, it calls it through the `helpers` proxy rather than
  `include`-ing the module.
- **Caching** — `app/controllers/concerns/live_widget.rb`. `cache_widget(ttl:)` sets:
  - Browser: `Cache-Control: public, max-age=0, stale-while-revalidate=86400`
  - Edge: `CDN-Cache-Control: public, max-age=<ttl>, stale-while-revalidate=3600, stale-if-error=86400`
    (RFC 9213 — Cloudflare honors it, browsers ignore it, which is what lets the edge TTL
    differ from the browser's `max-age=0`). ⚠️ Never express the edge policy as `s-maxage` —
    its presence disables `stale-while-revalidate` and `stale-if-error` (RFC 9111 §4.2.4),
    which is what keeps widgets rendering through a fly outage.
  ⚠️ Only emit this on successful, cacheable responses — an error must never be pinned at the
  edge. Edge `stale-while-revalidate` defaults to one hour
  (`DEFAULT_EDGE_STALE_WHILE_REVALIDATE`); the pageviews, trending, and related-articles
  widgets pass `edge_stale_while_revalidate: 1.day` since their data changes slowly relative
  to the hourly edge max-age.
- **Error reporting** — `config/initializers/bugsnag.rb` wires the `bugsnag` gem; its railtie
  auto-inserts the Rack middleware and hooks ActionDispatch, so unhandled exceptions are
  reported even though errors render as plain text. `notify_release_stages` is limited to
  `production` and `BUGSNAG_API_KEY` is unset locally/in CI, so it's a no-op outside production.
- **Errors** render as plain text via `lib/plain_text_exceptions.rb`. Unmatched paths are
  caught by the trailing `match "*unmatched"` route → `ApplicationController#route_not_found`
  (plain-text 404), instead of raising `ActionController::RoutingError`. This is what keeps
  scanner probes (`/api/.env`, `/wp-login.php`, …) to a single clean `status=404` lograge line
  rather than an exception backtrace. That catch-all **must stay the last route** in
  `routes.rb` or it will shadow everything below it — enforced by
  `spec/routing/routes_guard_spec.rb`.
- **Abuse mitigation** — `config/initializers/rack_attack.rb` (rack-attack middleware, wired
  up in `application.rb`). The origin is hit directly by vulnerability scanners, so it
  blocklists obvious probe paths (a flat 403 by **path pattern**, before routing) and throttles
  requests **to paths outside the known route prefixes** (keyed on the real client IP via
  `Request#client_ip`: **`CF-Connecting-IP` → `Fly-Client-IP` → `req.ip`**. There are two proxies
  in front — the zone is proxied through **Cloudflare**, so `Fly-Client-IP` is a Cloudflare PoP,
  not the visitor, and Rack's `req.ip` is a shared fly LB address. `CF-Connecting-IP` is only
  trustworthy on traffic that actually traversed Cloudflare, so it must stay confined to the
  throttle — never to anything that bans).
  ⚠️ The probe blocklist must stay **IP-agnostic** — never ban by IP. Some probe paths (e.g.
  `/widgets/.env`) are reachable through the public `/widgets/*` proxy, and all
  legitimate widget traffic shares that proxy's egress IPs, so an IP ban would 403 every
  visitor's widgets at once (this once took the site down). Same reason: do **not** add a
  blanket per-IP throttle.
  The throttle treats anything outside `RACK_ATTACK_KNOWN_PREFIXES` (`/up`, `/api`, `/widgets`,
  `/webhooks`, `/whoop`, `/sidekiq`, `/login`, `/logout`, `/auth`, `/`) as a probe: **if you add a top-level route, add
  its prefix there** or it will be rate-limited (the `/sidekiq` UI and the OAuth login routes are
  in the list for exactly this reason) — a missing prefix fails
  `spec/routing/routes_guard_spec.rb`. Disabled in the
  test env (`Rack::Attack.enabled`); counters live in Redis (in-memory under test).
  There's also a scoped `contact/ip` throttle (`POST /api/contact`, 5/hour) — the one place it's
  safe to key on a per-visitor IP, because it uses the proxy-forwarded **`X-Kona-Client-IP`** (the
  real visitor, not the shared egress) and it's a throttle (429), never a ban.
- **Redis** — global `$redis` from `config/initializers/redis.rb`, configured via `REDIS_URL`.
  In production this is the API's own dedicated `kona-redis` fly app (`redis/fly.toml` at the
  repo root); `web/` uses a separate Upstash instance, so the keyspaces don't overlap. The same
  Redis backs the Sidekiq queues. fly.toml runs two process groups: `app` (Puma) and `worker`
  (Sidekiq).

## Commands

```bash
bin/dev                                              # local server (or bin/setup)
bundle exec sidekiq -C config/sidekiq.yml            # local worker (needed to drain jobs)
bundle exec rspec spec/requests/widgets/activity_stats_spec.rb   # single spec (fast)
bundle exec rspec                                    # full suite
bin/ci                                               # setup + full suite + security scan (CI)
bundle exec brakeman -q --no-pager                   # static security scan
bundle exec bundle-audit check --update              # dependency CVE scan
fly deploy                                           # deploy to fly.io (app + worker processes)
fly console                                           # production console
```

No Rubocop / linter is configured. `.rspec` requires `spec_helper`. CI (`bin/ci` and the
`security` job in `.github/workflows/api.yml`) runs Brakeman + bundler-audit; the deploy job
**won't run unless both pass**. If Brakeman flags a verified false-positive, add a checked-in
`config/brakeman.ignore` rather than weakening the code.

## Testing

RSpec request specs in `spec/requests/`, plus `spec/services/` and `spec/presenters/`.
No DB or fixtures — stub services with
`allow_any_instance_of(SomeService).to receive(:method).and_return(...)`. Specs assert
the rendered markup **and** the cache headers.

## Environment variables

Names only — see `.env.example`; never commit values. Production values live as fly.io
secrets (and Rails `config/credentials.yml.enc` + `master.key`).

- **Required**: `REDIS_URL`, `ICU_ATHLETE_ID`, `ICU_API_KEY`, `FONT_AWESOME_API_TOKEN`,
  `WHOOP_CLIENT_ID`, `WHOOP_CLIENT_SECRET`, `WHOOP_REDIRECT_URI`, `GOOGLE_OAUTH_CLIENT_ID`,
  `GOOGLE_OAUTH_CLIENT_SECRET`, `OWNER_EMAIL` (the three gate owner sign-in for `/whoop/auth`
  + `/sidekiq` — Google OAuth restricted to this email/its hosted domain), `GOOGLE_API_KEY`,
  `API_TOKEN` (bearer required on all `/widgets/*` endpoints — injected by the web proxy —
  and on `POST /api/location` + `POST /api/contact`; must match the web app's),
  `WEATHERKIT_KEY_ID`, `WEATHERKIT_TEAM_ID`, `WEATHERKIT_SERVICE_ID`,
  `WEATHERKIT_PRIVATE_KEY` (base64 .p8), `CONTENTFUL_SPACE`, `CONTENTFUL_TOKEN`,
  `CONTENTFUL_WEBHOOK_SECRET` (64-char HMAC secret for the Contentful webhook), `SITE_URL`
  (public site root — the standard.site publication `url`, the contact form's no-JS redirect
  target, and Akismet's `blog` param), `RESEND_API_KEY`
  (the contact form's email delivery — an HTTPS API, so it works from fly, which blocks outbound
  SMTP), `CONTACT_FROM_ADDRESS` (the contact form's `from` — a sender address on a domain
  verified in Resend; Resend needs only SPF/DKIM, so it coexists with a Google Workspace mailbox
  on the same domain without touching the root MX; never hardcode the host), `CONTACT_TO_ADDRESS`
  (where contact-form messages are delivered — the recipient inbox, decoupled from
  `OWNER_EMAIL`).
- **Optional**: `AKISMET_API_KEY` (contact-form spam check; unset = Akismet off, submissions
  delivered unchecked. When set it fails **closed** — an Akismet outage retries the intake job
  rather than delivering unchecked), `TURNSTILE_SECRET` (contact-form Turnstile siteverify; fails open
  when unset — pair it with the web app's `TURNSTILE_SITE_KEY`, set both or neither),
  `FONT_AWESOME_VERSION`, `WHOOP_REFERRAL_URL`,
  `TRAINERROAD_CALENDAR_URL`
  (rest-day check + planned-workout matching for generated activity descriptions),
  `ANTHROPIC_API_KEY` + `ANTHROPIC_DESCRIPTION_MODEL` (the LLM lines of generated activity
  descriptions; the default model is `claude-sonnet-5`) — `ANTHROPIC_API_KEY` also powers the
  contact form's `ContactSubject` line, with an optional `ANTHROPIC_CONTACT_SUBJECT_MODEL`
  override (default `claude-sonnet-5`; `claude-haiku-4-5` is a cheaper fit),
  `PURPLEAIR_API_KEY`, `LOCATION`, `TIME_ZONE`, `BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD`,
  `BLUESKY_PDS_URL` (standard.site publishing; no-ops when the handle/password are unset),
  `BUGSNAG_API_KEY` (error reporting; **production only** — notifies only in the production
  release stage, and is unset in development/CI, so it's a no-op there),
  `ALLOWED_HOSTS` (comma-separated `Host`-header allowlist; **production only**, enables
  host authorization. Unset = all hosts accepted, so it's safe to deploy before setting it,
  then activate by setting the fly secret. `/up` is always exempt. Never hardcode the host),
  `GITHUB_DISPATCH_TOKEN` + `GITHUB_REPOSITORY` (the `SiteBuildJob` web-rebuild trigger — a
  fine-grained PAT with **Contents: Read and write**, or a classic PAT with `repo`, plus the
  `owner/repo` slug; both unset = the trigger no-ops, so dev/CI stay inert).

## Conventions & gates

- **Before committing/deploying** (non-negotiable): `bundle exec rspec` passes.
- Keep widget markup in sync with the matching `web/` placeholder (root `CLAUDE.md`).
- Font Awesome icons are fetched on demand by family/style/id (GraphQL) and cached per
  version in Redis — `icon_svg('classic', 'solid', 'eye')`. No allowlist needed here;
  any id a view references is fetched. The Font Awesome integration lives **only** here:
  the `FONT_AWESOME_API_TOKEN` and `FONT_AWESOME_VERSION` env vars, the GraphQL client, and
  the SVG cache are all api-side. The `web/` build no longer talks to Font Awesome directly —
  it POSTs its own allowlist to `POST /api/icons` (`Api::IconsController`), which resolves each
  id via the same `FontAwesome` service (so a new web icon needs no api change). That endpoint
  requests icons in small batches, so a cold cache can't blow the per-request `rack-timeout`;
  don't change it to resolve the whole allowlist in one request.

### Permissions

- Autonomous: read files, single-file `rspec`, local `bin/dev`.
- Ask first: `fly deploy`, secret changes, anything that flushes Redis,
  `git push`/commit, package installs.
