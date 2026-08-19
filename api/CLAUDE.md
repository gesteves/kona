# api/ — Kona widget API

Rails 8.1 API (Ruby 4.0.6) serving small embeddable **HTML fragments** ("widgets"), plus
structured-data endpoints and inbound webhooks, for the static `web/` site. Deployed to **fly.io**
as `kona-api` (`app` + `worker` processes), with the origin proxied behind **Cloudflare**.
Redis-backed caching, **no database**.

Minimal Rails: only ActiveModel + ActionController + ActionView are loaded (no ActiveRecord /
ActiveJob / ActionMailer / ActionCable). See the root [`CLAUDE.md`](../CLAUDE.md) for the web↔api
markup contract before changing any view, and for the comment-style conventions this app follows.

It also serves a small owner-facing **admin UI**, built on Web Awesome and mounted at the root of
the admin host — the only part of the app with an asset pipeline or a layout. See **The admin UI**
below.

Routes split by namespace: `/widgets/*` (HTML fragments, reached through the web app's proxy),
`/api/*` (structured data, hit directly at the origin), `/webhooks/*` (inbound, hit directly by
the sending service).

The origin answers on **two hostnames**, and the split is enforced in `config/routes.rb`: `API_HOST`
names the public one, and the owner-facing routes are drawn only off the *other* one (the admin
host), so the public host serves nothing but `/up` and those three namespaces. ⚠️ **A new
owner-facing route must go inside that `constraints` block** — the zone's bot-protection skip rule
is scoped to "every host except the admin one", so a route drawn outside it is reachable on the
public host with managed rules and Super Bot Fight Mode skipped.
`spec/requests/host_constraints_spec.rb` pins both directions.

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
| POST | `/api/location` | sets Redis `location:current` + enqueues `LocationSyncJob`, via `Location.store` | — |
| POST | `/api/contact` | drops honeypot hits + enqueues `ContactMailJob`; JSON → 204/422, HTML → 303 | — |
| POST | `/api/build` | enqueues `SiteBuildJob`; 202, or 429 inside the 60s dedupe lock | — |
| POST | `/api/icons` | resolves the web build's Font Awesome allowlist to SVGs | — |
| GET | `/api/standard-site` | `{did, publication_uri}` for the build's verification markup | 1 hr |
| POST | `/webhooks/contentful` | enqueues PDS sync, embedding, asset-mirror, and site-build jobs; 204 | — |
| POST | `/webhooks/whoop` | enqueues `WhoopWebhookJob`; 200 `{ok: true}` | — |
| GET | `/whoop/auth`, `/whoop/callback` | Whoop OAuth (authorize is owner-gated) | — |
| GET | `/signin`, `/auth/google_oauth2/callback`; POST `/signout` | owner session | `no-store` |
| GET | `/`, `/spam`, `/location`, `/connected-apps`, `/course-maps`, `/course-maps/:id` | admin UI (owner-session gated) | `no-store` |
| POST | `/spam/:id/not-spam`; DELETE `/spam/:id`, `/connected-apps/whoop` | release or delete a quarantined message; disconnect Whoop | `no-store` |
| GET/POST/DELETE | `/connected-apps/bluesky` | the Bluesky handle + app password form, and disconnect | `no-store` |
| POST | `/location` | same write as `POST /api/location`; answers with the geocoded place | `no-store` |
| POST | `/course-maps`; PATCH/DELETE `/course-maps/:id`; GET `/course-maps/status` | upload GPX tracks, save render settings, delete a track, poll publish status | `no-store` |
| GET | `/course-maps/:id/preview`, `/course-maps/:id/download` | the rendered PNG, proxied from Mapbox; same render, only the disposition differs | `no-store` |
| — | `/sidekiq` | job dashboard (owner-session gated) | — |
| GET | `/` (public API host only) | 301 → main site | — |

The Whoop OAuth, owner session, admin UI, and `/sidekiq` rows are **admin-host only** wherever
`API_HOST` is set.

⚠️ **`/` is the one path the two hosts answer differently** rather than one of them 404ing: the
admin home page sits at the root of the admin host, and the public host keeps the redirect to the
main site. Two routes are drawn for `/`, and only the `API_HOST` constraint plus **the order they
appear in** keeps them apart — swapping them would silently hand the public host the admin UI.
`spec/requests/root_spec.rb` and `spec/requests/host_constraints_spec.rb` pin both directions.

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
`StandardSite`, `AssetMirror`, plus five that aren't `ApplicationService` subclasses because they
aren't cacheable reads: `SpamQuarantine`, `TrackLibrary`, and `BlueskyCredentials` (Redis-only, no
HTTP), `GpxTrack` (parsing only), and `MapboxTileset`/`StaticMap` (see
**The course-map renderer**).
Read-through Redis cache via `cached_json(key, expires_in:)`;
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
| `ActivityDescriptionJob(activity_id, whoop_strain = nil)` | (re)generates an activity's Strava description and tidies its name |
| `LocationSyncJob(latitude, longitude)` | propagates the current location to Intervals.icu |
| `ContactMailJob(name, email, message, context, restored_from_spam = false)` | contact intake: Akismet + compose |
| `ContactDeliveryJob(payload)` | the one retryable *delivery* unit — sends via Resend |
| `MapTilesetJob(id)` | publishes an uploaded GPX track to Mapbox as a vector tileset |
| `WhoopTokenRefreshJob()` | forces a Whoop token refresh on a schedule (see below) |

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
  activity by a Redis lock. The same PUT tidies a Rouvy-generated name
  (`ROUVY - <route> - <date>` → `Rouvy - <route>`), so it can write even when the description
  composes empty.
- ⚠️ **Turnstile guards only the JSON path** (`request.format.json?`), so a scripted POST that
  omits `Accept: application/json` skips it entirely. Reviewed and **accepted**: the widget needs
  JS, and enforcing it on both paths would break the no-JS fallback by definition. What actually
  stops automated abuse is the honeypot, Akismet (which fails *closed* when configured), the
  length caps, and the 5/hour `X-Kona-Client-IP` throttle — don't thin those out on the assumption
  Turnstile is carrying them. Closing the gap properly means a second factor the no-JS path can
  also present, e.g. a signed expiring token minted into the form.
- **The contact form is a two-job pipeline** so a Resend failure retries only the send. Akismet
  fails closed, so an outage retries the *intake* job rather than delivering an unchecked message;
  `ContactSubject` (a Claude-generated subject line) fails soft. A flagged message is **quarantined,
  not dropped** (see **The spam quarantine**); `restored_from_spam` is the owner releasing one, which
  skips the check and reports the false positive.

Config in `config/initializers/sidekiq.rb` and `config/sidekiq.yml`. Sidekiq runs as a dedicated
**`worker` fly process**; a worker must be running to drain the queue (locally: `bundle exec
sidekiq`).

**Recurring jobs** come from `sidekiq-scheduler`, whose schedule lives under `:scheduler:` in
`config/sidekiq.yml` and which only starts inside the Sidekiq **server** — Puma loads the gem and
schedules nothing, so there's no double-firing across the two fly machines. Its "Recurring Jobs"
tab rides along on the owner-gated `/sidekiq` dashboard. Only `WhoopTokenRefreshJob` is scheduled
today (every 6 hours): Whoop rotates its refresh token on every refresh and expires an idle one,
but tokens are otherwise refreshed **only on demand**, so a quiet stretch with no widget traffic
and no webhooks would leave the integration needing a manual re-auth at `/whoop/auth`. The job
goes through `Whoop#refresh_tokens!`, which forces past the access-token cache but still takes the
same refresh lock. When Whoop rejects the token anyway, the failure surfaces on the Connected apps
page rather than only in Bugsnag — see below. ⚠️ **Schedule entries must use `cron:`, not `every:`** — rufus measures an
`every` interval from process start, so a 6-hour one would reset on every deploy and could go
indefinitely without firing.

### Views, helpers, presenters

Views (`app/views/widgets/`) render raw HTML fragments. **Helpers** (`app/helpers/`) are pure
formatting/selection functions — every method takes the data it works on as explicit arguments;
none read controller ivars. Request state lives in **presenters** (`app/presenters/`):
`WeatherSummaryPresenter` (the weather widget's prose + business rules), `EventWeatherPresenter`,
`UpcomingRacesPresenter`, `WhoopPresenter`. Presenters take their data as constructor kwargs. When
a controller body needs a helper, it calls it through the `helpers` proxy rather than `include`-ing
the module.

### The admin UI

An owner-facing UI built with **Web Awesome Pro** components. It's the only part of this app with an
asset pipeline, a layout, or client-side JavaScript; everything else still renders `layout false`
fragments.

⚠️ **Its routes sit at the ROOT, not under `/admin`** — they're drawn only on the admin host, where
the prefix would just repeat the hostname. `scope module: "admin"` in `config/routes.rb` keeps the
controllers grouped under `Admin::` without putting that in the path. The consequence is that admin
pages claim top-level paths: check any new one against the zone's scanner-noise custom rule, which
blocks whole prefix families (`/config/`, `/home/`, `/analytics/`, `/deploy/`, …) zone-wide and
would 403 a page named after one. Add its prefix to `RACK_ATTACK_KNOWN_PREFIXES` too.

**Stack: Turbo + Stimulus + Web Awesome, server-rendered.** No SPA framework, and no separate
front-end app — deliberately, and not for lack of ambition (a maps UI, a daily dashboard, and
eventually a Contentful replacement are all intended to live here). Web Awesome already ships the
admin component set those need, and keeping it as the single component layer across `web/` and
`api/` is what stops the design system forking. When one screen turns out to need real client state,
add it as an **island**: npm install, import in `app/javascript/admin.js`, mount from a Stimulus
controller's `connect()`. The pipeline supports that with no changes.

**Pipeline**: Propshaft (fingerprinting) + jsbundling-rails (runs `npm run build` inside
`assets:precompile`) + esbuild, configured in `esbuild.config.mjs` rather than CLI flags (as `web/`
uses) because the Sass plugin has to be registered in-process. `app/javascript/admin.js` is the only
entrypoint; esbuild emits `app/assets/builds/admin.js` *and* a sibling `admin.css` from the
stylesheet imports. Bundling exists because Web Awesome's `dist/` uses relative imports into
`dist/chunks/*.js` and Propshaft rewrites no import specifiers.

**Styles are Sass**, one BEM block per partial under `app/javascript/styles/`, pulled together by
`admin.scss`. ⚠️ **esbuild — not Sass — is what flattens `webawesome.css`.** That file is a chain of
`@import url(...)` statements, and Sass passes those through as plain CSS imports instead of
inlining them, which would leave the built stylesheet pointing at paths that don't exist. So the
vendor stylesheet stays a plain `.css` import in `admin.js`, ahead of our `.scss`.

- ⚠️ **`WEBAWESOME_NPM_TOKEN` is required at every `npm ci`** — your shell, the GitHub runner, and
  **fly's remote builder** (`flyctl deploy --build-secret`, which is why the deploy command grew a
  flag). `.npmrc` interpolates it from the environment; it's never on disk.
- ⚠️ **`node_modules` is deleted at the end of the Dockerfile's build stage.** The final stage does
  `COPY --from=build /rails /rails` wholesale, so anything left behind ships to a 512MB VM.
- ⚠️ **The import of the full `styles/webawesome.css` is load-bearing**, not a convenience.
  `styles/layers.css` is what defines `.wa-mobile-only` and the rule hiding `[data-toggle-nav]` on
  desktop; `styles/utilities/fouce.css` is what provides `.wa-cloak`. Cherry-picking the theme (as
  `web/` does) silently drops both. Our Sass is imported *after* it and is unlayered, so it outranks
  every `wa-*` layer without specificity games.
- ⚠️ **Don't use `<wa-icon>`** — it resolves icons through a base path or FA kit code, neither
  configured here, and the npm package ships no icon assets, so every icon silently renders blank.
  Use `icon_svg(family, style, id)`, and **always with `raw`** — it returns a plain String, so
  without it ERB escapes the markup into the page as visible text. For an icon that goes into a
  component slot (`start`/`end` on `<wa-button>`, `icon` on `<wa-callout>`), use
  `slotted_icon_svg(family, style, id, slot:)`, which returns a safe buffer and needs no `raw`.
- ⚠️ **ARIA on a `wa-*` host does not reach the element inside its shadow root.** `<wa-button>`
  renders its own `<button>`/`<a>` and forwards `href`/`target`/`rel`/`type` but no ARIA, and
  `icon_svg` marks every SVG `aria-hidden` — so an `aria-label` or `aria-current` on the host is
  inert to a screen reader. Put the name or state in the **slotted content**, as a
  `wa-visually-hidden` span (the header toggle and the nav's current item both do). Turbo, by
  contrast, *does* pierce shadow roots in both directions — it finds a `wa-button`'s inner anchor
  through the click's composed path, and `data-turbo="false"` on the host from there — so
  `<wa-button href>` navigates with Drive like a plain link.
- ⚠️ `rake assets:*` is now shared: `assets:backfill` (the R2 image mirror, above) sits alongside
  Propshaft's `assets:precompile` / `clean` / `clobber`. No collision, but they're unrelated.

**Prefer a Web Awesome component over the native element wherever one exists**, and its layout
utilities (`wa-stack`, `wa-cluster`, `wa-grid`, `wa-gap-*`, `wa-visually-hidden`) and design tokens
(`--wa-space-*`, `--wa-color-*`, `--wa-form-control-*`) over hand-written CSS. In practice that
means **not** `button_to`, which emits a native `<button>` — use `form_with` wrapping a
`<wa-button type="submit">`. Web Awesome's button is form-associated (`formAssociated = true`), so
it submits the surrounding form exactly like a native one, CSRF token and `_method` included.
A bare `<button` in the server HTML means one crept back in; two request specs assert its absence.

Sass here is for what's genuinely ours — page-specific layout, the brand pins, a border the
component doesn't draw. A rule that restates a component's own look (its radius, hover fill, focus
ring, control height) means the component's API was skipped: reach for `appearance` / `variant` /
`size` first, then its CSS custom properties, then `::part()`, and write a rule of your own last.
Same for markup: when a `wa-*` element seems to be missing a capability, check its docs before
working around it — several of the sharp edges here (`<wa-page>`'s navigation slot,
form-association, `::part(base)`) are documented behavior.

⚠️ **The package ships its own docs — read them rather than recalling an API.** They're the source
the vendor's examples come from, and they're versioned with the installed release:

- The **`webawesome` skill** is registered in this environment; invoke it for component APIs
  (attributes, slots, parts, events) and the utility/token reference.
- Both skills are on disk at `node_modules/@web.awesome.me/webawesome-pro/dist/skills/` —
  `webawesome/references/components/<name>.md` per component, plus `webawesome-design/` for layout
  and theming. The `<wa-page>` rules further down come from
  `webawesome-design/references/layouts-page.md`.
- When neither answers it, the component's own source and styles do
  (`dist/components/<name>/`, `dist/chunks/*.js`) — that's the only place the shadow-DOM behavior
  flagged above is written down.

**Brand color** — the site's firebrick (`#bf0222`, matching `--color-firebrick` in `web/`). Web
Awesome derives every brand surface from the `--wa-color-brand-NN` ramp, so there's no single token
to set: the layouts put **`wa-brand-red`** on `<html>` (Web Awesome's supported way to swap the whole
ramp to the red family, keeping its contrast-checked hover/quiet steps) and `styles/_tokens.scss`
pins `--wa-color-brand-50` — the step the *loud* surfaces paint with — to the exact firebrick. It
also colors the Turbo progress bar and the logo's hover state. ⚠️ Don't hand-write the other ten
ramp steps; that's what the palette exists to get right.

**Layouts** — `layouts/admin.html.erb` (the `<wa-page>` shell) and `layouts/auth.html.erb` (the
sign-in page, which is deliberately just the Google button — no heading, no copy), sharing
`layouts/_head.html.erb`. ⚠️ **Neither is named `application`**: that's
Rails' implicit default, and this app's posture is machine-only-by-default, so every existing
controller must stay unaffected even if a `layout false` is ever dropped. Dark mode comes from an
inline script mapping `prefers-color-scheme` onto Web Awesome's `.wa-dark` class — it keys off that
class, not the media query.

**`<wa-page>` rules** (the package ships its own reference at
`dist/skills/webawesome-design/references/layouts-page.md`): write the nav **once** in
`slot="navigation"` — the component moves that one copy between the desktop sidebar and the mobile
drawer, so a second authored copy shows twice on desktop. `--menu-width` must reset to `auto` for
`view='mobile'` or an empty band is reserved down the left. Nav links need `data-drawer="close"`.
⚠️ Set `disable-navigation-toggle` explicitly because we server-render: the component flips it
itself once it sees our `[data-toggle-nav]`, but not before it upgrades, and until then its built-in
hamburger renders on its own unstyled row above the header.

⚠️ **Two flows must opt out of Turbo** with `data-turbo="false"`: the Google sign-in form and the
Whoop **Connect** link. Both are same-origin URLs that redirect cross-origin, which Turbo Drive
cannot follow — it fails silently, the click appearing to do nothing. The Connected apps view
applies the attribute to every card's Connect button unconditionally; the only cost to one whose
path is an ordinary admin page (Bluesky's form) is a full page load.

The header carries the site wordmark, `layouts/_logo.html.erb` — a **verbatim copy** of
`web/source/partials/_logo.svg.erb`. ⚠️ Its paths hardcode `fill="#020a0a"`, which is invisible on
the dark theme; `_admin-header.scss` overrides that to `currentColor`, which is also why it's
inlined rather than served as an image (an `<img>` can't inherit the text color). Drift between the
two copies costs nothing beyond a stale admin logo.

The sidebar comes from `AdminHelper` — `#admin_nav_items` for the two ungrouped entries (Home,
Spam) and `#admin_nav_groups` for the labelled groups (Tools, Settings, More) — and both render
through `layouts/_admin_nav_item`, so drawer-closing, the active state, and icon handling are
written once. Each item is a `<wa-button appearance="plain" href>` with a leading icon, and the
current page's is set to `filled` — the active state is a Web Awesome step, not a hand-picked
background. An item marked `external: true` (today only Sidekiq, which renders its own layout)
opens in a new tab with `rel="noopener"` and a visually-hidden "(opens in a new tab)".

A group is nothing but a caption above its own `<ul>` of those same links:

- ⚠️ **The caption is a `<div>`, not a heading element** — it sits above the page's own `<h1>`, so a
  real heading would land ahead of it in the document outline. The `<ul>` carries
  `aria-labelledby` pointing at it, which is what associates the two for a screen reader.
- ⚠️ **Every item's icon box is forced square** in `_admin-nav.scss`, against the `width: auto`
  every inline SVG gets in `_base.scss` — Font Awesome's viewBoxes aren't all square, so at auto
  width no two labels in the column start at the same x.

**Connected apps** (`/connected-apps`) connects and disconnects Whoop and Bluesky.
`ConnectedAppPresenter` renders four states from a `valid_credentials?` / `connected?` pair plus an
optional `error:` string. The fourth, `:error`, is attached-but-broken, and it offers **both**
Reconnect and Disconnect — re-authorizing is the fix, and requiring a disconnect first would throw
away the only thing separating it from a fresh setup.

- **Whoop** is OAuth: `Whoop#disconnect!` clears the tokens. ⚠️ It deletes the cached `user_id`
  alongside them — `Webhooks::WhoopController` authorizes payloads against it, so a leftover copy
  keeps accepting webhooks for an account whose tokens are gone.
  - ⚠️ **A rejected refresh leaves the tokens in place**, so `connected?` — which is just "is there
    a refresh token" — keeps reporting true while nothing works. `Whoop#record_refresh_error`
    writes `whoop:<client id>:refresh_error` on a **4xx** from the token endpoint, and
    `#refresh_error` is what makes the card say so. **4xx only**: a 5xx or a timeout is Whoop being
    down, and flagging those would send the owner off to re-authorize working credentials. Cleared
    by `store_tokens` (so any successful refresh *or* re-auth clears it) and by `disconnect!`.
- **Bluesky** has no OAuth round trip, so it connects by form at `/connected-apps/bluesky`
  (`Admin::BlueskyController`, which owns all three of its actions rather than splitting the
  disconnect onto `connected_apps#`). `BlueskyCredentials` holds the handle and app password in
  the Redis hash `bluesky:credentials`. ⚠️ **That page is the only way to set them — there is no
  env var**, so the integration is inert on a fresh environment until someone connects.
  - ⚠️ **The app password is encrypted at rest** (`ActiveSupport::MessageEncryptor` off
    `secret_key_base`) — it's an account-level credential that works from anywhere with no client
    binding, and this Redis also backs the Sidekiq queues. It's the only encrypted value in the
    app. A decrypt failure returns nil rather than raising, so a rotated `RAILS_MASTER_KEY`
    degrades to "not connected" instead of erroring every page that renders the status.
  - ⚠️ **`StandardSite#connect!` validates before storing**, by opening a real PDS session. A
    typo'd app password stored blind fails silently on the next publish.
  - ⚠️ **`disconnect!` deliberately leaves `standard_site:did` alone.** The DID is public data, not
    a credential, and `GET /api/standard-site` feeds the verification `<link>` tags on every page
    of the static site — clearing it would strip them site-wide at the next build, under a 60s
    cache that never looks like an edge anomaly.
  - ⚠️ **A DID change drops the publication record's fingerprint.** Document fingerprints cover
    the publication's `at://` URI, which carries the DID, so they invalidate themselves when the
    account changes; the publication record's doesn't, and a stale one would report `:unchanged`
    forever and never sync to the new repo.
  - ⚠️ **Flushing Redis costs a reconnect** — the credentials live only there, and nothing else
    can re-derive them.

### The spam quarantine

**Spam** (`/spam`) lists everything Akismet flagged, newest first, with **Not spam** and
**Delete forever**. `ContactMailJob` stores a flagged submission via `SpamQuarantine` instead of
dropping it; **Not spam** re-enqueues that job with `restored_from_spam`, which skips the check and
calls `Akismet#submit_ham`.

- **One Redis hash**, `contact:spam`, field = a generated id. Deliberately not a key per message:
  nothing else here enumerates the keyspace, and this Redis also backs the Sidekiq queues, so a
  `SCAN` would be the first of its kind. ⚠️ The trade is that the 30-day retention is enforced in
  Ruby, so `#store` prunes as well as `#all` — **pruning on the write path is what bounds growth
  when nobody opens the page.**
- ⚠️ **`SpamQuarantine#take` is fetch-and-remove, and the `HDEL` return value is the guard.** Turbo,
  a double click, or a bfcache replay can fire "Not spam" twice; releasing on the read alone would
  send the email twice.
- ⚠️ **`Akismet#submit_ham` fails soft, inverting the rest of that class.** `#spam?` raises so
  nothing is delivered unchecked; the ham report is training, and must never stand between the owner
  and a message they've already judged legitimate.
- ⚠️ **These cards are the only unfiltered attacker input this app renders as HTML.** ERB's default
  escaping is the whole defense — no `raw`, no `html_safe`, no `simple_format` on a message field.
  The `raw icon_svg(...)` idiom used everywhere else in the admin must not spread to them. Line
  breaks come from `white-space: pre-wrap`. A request spec pins it with a `<script>` payload.
- ⚠️ **`wa-details` and `wa-dialog` are exempt from the "don't use `<wa-icon>`" rule** — their
  chevron and close icons pass `library="system"`, which resolves to inline data URIs bundled with
  the component, no kit code involved. The delete confirmation is fully declarative
  (`data-dialog="open <id>"` / `data-dialog="close"`); the `dialog` Stimulus controller only closes
  it before Turbo caches the page.
- The card's **Delete forever** is `variant="neutral"`, not `danger`: the brand ramp here *is* red,
  so a danger variant beside the brand-accent "Not spam" makes the safe action the loudest thing on
  the card. Red is reserved for the confirm button inside the dialog.

### The location picker

`/location` is a full-width Mapbox map with a draggable pin, and the pin **is** the current
location: a click or a drag writes it, with no separate save step. Above the map sit the place name,
the coordinates and a Geolocation button — that line is the only confirmation there is, so it
reports "Saving…" and then what was stored.

- **It writes through `Location.store`**, the same method `POST /api/location` uses, so the two
  can't drift on ordering (Redis first, sync second) or on validation (`Location.parse`, which is
  `Float()` rather than `to_f` — see the Null Island ⚠️ there). This page is a front-end over that
  endpoint's write, not a second way to store a location.
- **The heading is `format_location`'s output** — the same helper, over the same
  `GoogleMaps#location`, that `WeatherSummaryPresenter` renders — so the page doubles as a preview
  of how a location will read in the weather widget. ⚠️ Not `LocationContext#label`, which adds
  fallbacks ("Current location") the widget doesn't have; the preview would promise a name the
  widget would never print. A geocode that resolves to nothing falls back to the coordinates.
- ⚠️ **`POST /location` answers with that place, and the page updates the heading from the
  response.** Re-deriving it per drop is the point: the server-rendered name describes the location
  the page was *loaded* with, and one pin drop makes it a caption for the wrong place.
- ⚠️ **The displayed coordinates are rounded, and the rounding is written twice** —
  `LocationPresenter::DISPLAY_PRECISION` for the server-rendered line and `DISPLAY_PRECISION` in
  `location_map_controller.js` for the one a pin drop rewrites. They must match, or dropping a pin
  visibly reformats the numbers. Storage is unaffected: the controller still saves at its own
  `PRECISION`, and the override callout deliberately prints the env var's value verbatim.
- ⚠️ **`Location` prefers `ENV["LOCATION"]` over the stored value**, so with that var set a pin
  drop writes Redis and changes nothing any widget reads. The page renders a callout naming the
  coordinates that actually win rather than appearing to work.
- ⚠️ **The map's token is `MAPBOX_ACCESS_TOKEN` and only that.** It's rendered into the page, and
  `StaticMap`'s preference for `MAPBOX_SECRET_TOKEN` is exactly the fallback that must not happen
  here — that token carries `tilesets:write`. A request spec asserts it never appears in the body.
  Without the public token the map is replaced by a callout and the coordinate form still works.
- **Mapbox GL JS comes from Mapbox's CDN, loaded by the Stimulus controller**, not from npm. It's
  several times the size of the whole admin bundle and one page wants it, and the map already
  can't work without `api.mapbox.com`, so this adds no dependency the page didn't have.
  ⚠️ Loaded from the controller rather than a `<head>` tag because Turbo merges a new head by
  *appending* elements: a deferred script would land asynchronously and the controller could
  connect before `mapboxgl` existed.
- ⚠️ **The map is torn down on `turbo:before-cache`.** Turbo snapshots the page before Stimulus
  disconnects, so without it the cached copy contains GL JS's canvas and a restoration visit
  builds a second map on top of the dead one.
- The geocode is display only and degrades to nothing, so an unset `GOOGLE_API_KEY` — or a bad day
  at Google — leaves the coordinates and stores the location regardless.

### The course-map renderer

`/course-maps` turns GPX tracks into the static PNG cover images used on race reports. It's a
front-end over Mapbox's Data Workbench: upload one or more GPX files, wait for each to be
published as a private vector tileset, then open one to tune its framing and styling and download
the result.
(This replaced a standalone `utilities/maps/` Rake task, which rendered every GPX in a folder with
one shared set of env-var options.)

Four services, none of them `ApplicationService` subclasses: `GpxTrack` parses an upload,
`TrackLibrary` is the Redis store, `MapboxTileset` talks to the Mapbox Tiling Service, and
`StaticMap` builds and fetches the render.

- ⚠️ **Nothing is composited locally.** The Static Images API draws the track (an `addlayer` over
  the tileset) and both pins server-side and returns a finished PNG, so this needs no image library
  and no system packages — only `nokogiri` and `httparty`. Don't "improve" it into local drawing;
  the 512MB VM has an OOM history.
- ⚠️ **`GpxTrack` streams with `Nokogiri::XML::Reader`, not a DOM.** Real Garmin exports run to
  several megabytes and ~9,000 points, and this parse happens in a Puma thread against a 20-second
  request budget. Coordinates are rounded to six decimals (~11cm) on the way in: Garmin writes 26
  significant digits, which triples both the Redis payload and the Mapbox upload for nothing.
- **One Redis hash**, `maps:tracks`, field = the tileset id — same reasoning as the spam
  quarantine. A record holds the bounding box, both endpoints, the sport, and the render settings,
  because **the GPX is thrown away after upload** and the settings page still has to place the pins
  on a track uploaded last week. `MAX_ENTRIES` is a runaway guard, not retention: a track is only
  gone when the owner deletes it.
- ⚠️ **Coordinates are staged in their own key** (`maps:pending:<id>`, 1-hour TTL), not in the
  record or the job's arguments. `app` and `worker` are separate fly machines, so a tempfile
  written during the request isn't there for the worker to read.
- ⚠️ **`MapTilesetJob` raises on failure rather than recording one**, so the inherited 24-hour
  retry applies; `sidekiq_retries_exhausted` is what writes `status: "failed"`. Recording it on the
  first exception would flicker the row failed → processing → failed on every attempt. The job is
  idempotent (source upload replaces, an existing tileset counts as success), which is what makes
  that safe — and necessary, since `kill_timeout` is 30s and a publish poll runs up to 300s.
- ⚠️ **`MapboxTileset#destroy!` deletes the tileset *and* its source.** Deleting only the tileset
  orphans the source, which still counts against the account and is invisible in the tileset list.
  It raises on anything but success or 404, so the local record is never dropped while the remote
  one survives.
- ⚠️ **`preview` and `download` proxy the render; they never redirect.** The Static Images URL
  carries `MAPBOX_SECRET_TOKEN` as a query parameter, so an `<img>` pointed at Mapbox would hand
  the browser a `tilesets:write` credential. Both render at `@2x` — the API bills per request, not
  per pixel, so a smaller preview saves nothing, and the zoom dialog shows that same image at full
  width, where 1x would be half the pixels a retina screen wants.
- ⚠️ **The style URL and the marker icons/colors reach an outbound URL from form fields**, so
  `StaticMap` matches the style against Mapbox's own shape and strips everything that isn't an icon
  id or a hex color. A bad style falls back to the default rather than being interpolated, and the
  per-side numbers are clamped — they come from number inputs.
- **Padding and extra map are four settings each**, not the CSS-style shorthand string the Rake
  task took (`PADDING=60,20`). The form shows one field while the sides match and four when they
  don't; `linked_sides_controller` mirrors the first into the rest, and all four stay named so the
  form always submits four values. Shorthand was compact to type and miserable to edit.
- **The map style is a dropdown plus an override.** `style_preset` holds one of `STYLE_PRESETS`,
  `style_url` holds a custom style and wins when set. `MapTrackPresenter#settings` moves a preset
  found in `style_url` back into the dropdown, which is also how records written before the split
  migrate themselves.
- **Marker icons are named for what they mark** (`MARKER_ICONS`), not by their Maki id, and the
  sport→icon seeding in `GpxTrack::SPORT_ICONS` falls back to running rather than to a neutral
  placeholder.
- ⚠️ **Mapbox draws the last overlay on top**, so the default marker order is `[finish, start]` —
  start on top, because a finish pin over the start of an out-and-back hides where you began.
  `finish_on_top` reverses it. The setting is named for the state it produces; an earlier
  `reverse_markers` described the mechanism and read backwards against its own label.
- ⚠️ **The pinned preview clears the sticky header via `<wa-page>`'s `--header-height`**, which the
  component declares but never measures — `_page.scss` sets it, `_admin-header.scss` takes the
  bar's height from it, and `_track.scss` offsets the sticky preview by it. Setting it also fixes
  the component's own `--scroll-margin-top` for anchor targets.
- ⚠️ **This is the only admin page that needs the Sidekiq worker running.** A track sits on
  "Processing" until `MapTilesetJob` publishes it. That's why `worker` is no longer opt-in in
  `.overmind.env`. The index checks Sidekiq's process set **only while something is publishing**
  and says so when it's empty — otherwise a stuck row looks identical to a slow one, with nothing
  anywhere explaining it. In production an empty set means the worker machine is down.
- **The page polls**, it doesn't push: `map_status_controller` re-checks `/course-maps/status` every 5s
  while a row is publishing and stops otherwise. Action Cable's engine is commented out in
  `application.rb` and there's no `turbo-rails`, so a websocket would be a lot of new
  infrastructure for one signed-in user.
- **`map_preview_controller` rewrites the image's `src` rather than submitting the form.** A submit
  is a Turbo visit, which replaces the body — the field being edited would lose focus on every
  keystroke and a slider would stop tracking mid-drag. The form stays a real GET form so pressing
  Enter, or running without JavaScript, still works. Each rebuild is one billed Static Images
  request, hence the debounce.
- These are the admin's **first form inputs** — every other form here is action-only. Web Awesome's
  controls are form-associated, so they submit and appear in `FormData` like native ones. The
  marker-order switch is paired with a hidden `0` field, because an unchecked switch submits
  nothing.

`Admin::BaseController` requires the owner session; it, `SessionsController`, and
`WhoopOauthController` all include the **`OwnerFacing`** concern, which sets `Cache-Control:
no-store`, `X-Robots-Tag: noindex, nofollow`, and the **CSP** below. ⚠️ Admin actions must never
call `cache_widget`. ⚠️ The `X-Robots-Tag` is not redundant with the `<meta name="robots">` in the
layout: `public/robots.txt` disallows this whole host, so a crawler never fetches the page to *see*
that tag, while the URL can still be indexed from an external link. ⚠️ `WhoopOauthController` is in
that list for the `no-store` specifically — its callback carries the OAuth `code` and `state` in
the query string, and it renders no admin layout that could carry the signal instead.

**Content-Security-Policy** — declared in `OwnerFacing`, so it lands on these three and nowhere
else. ⚠️ `config/initializers/content_security_policy.rb` sets **only** the nonce generator and
`nonce_directives`, and deliberately declares **no default policy**: a global one would put the
header on every widget fragment, which isn't a document and whose response is stored in the edge
cache. `spec/support/live_update_contract.rb` fails if a fragment ever grows one.

- Sent as **Report-Only** unless `CSP_ENFORCE` is set, so a forgotten source is a console report
  rather than a blank admin page — and flipping it is a fly secret rather than a deploy.
- ⚠️ The nonce is scoped to `script-src` **only**. A nonce in a directive makes browsers ignore
  `unsafe-inline` in that same directive, and `style-src` needs `unsafe-inline` for the styles Web
  Awesome and Mapbox GL JS write at runtime. Adding `style-src` back to `nonce_directives` would
  silently break every component.
- The inline dark-mode script in `layouts/_head.html.erb` carries that nonce. It has to stay
  inline and before paint, so the nonce is what keeps it running.
- `MAPBOX_ORIGINS` is the location picker: GL JS and its stylesheet come from `api.mapbox.com` at
  runtime, and the map then reaches the tile and telemetry hosts directly. GL JS also runs its
  renderer in a Worker built from a blob URL, hence `worker-src blob:`.
- ⚠️ `Sidekiq::Web` renders its own layout with its own `csp_nonce` and is not covered by this.

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
  throttle, never a ban. And a `signin/ip` throttle (30 per 5 min) over `/signin` + `/auth/` —
  ⚠️ those prefixes are in `RACK_ATTACK_KNOWN_PREFIXES`, which is exactly what exempts them from
  the `unknown-paths` throttle, so without a rule of their own the login surface had no
  origin-side limit at all. Keying on `client_ip` is safe *there* because those paths live on the
  admin host, which nothing reaches through the shared widget-proxy egress.
- **The owner session** is Rails' cookie store, declared in `config/initializers/session_store.rb`
  only to add `expire_after`. ⚠️ A cookie session has no server-side record, so there is nothing to
  revoke — short of rotating `secret_key_base`, a stolen cookie is valid until the browser drops
  it. The expiry is the ceiling.
- **Redis** — global `$redis` from `config/initializers/redis.rb`, via `REDIS_URL`. The same Redis
  backs the Sidekiq queues.

## Commands

Run `nvm use` before any `npm` command, as in `web/`.

```bash
bin/dev                                                          # local server (or bin/setup)
npm run build                                                    # admin bundle, one shot
npm run watch                                                    # …or rebuild on change (the `js` overmind process)
bundle exec sidekiq -C config/sidekiq.yml                        # local worker
bundle exec rspec spec/requests/widgets/activity_stats_spec.rb   # single spec
bundle exec rspec                                                # full suite
bin/ci                                                           # setup + suite + style + security
bundle exec rubocop                                              # -a to autocorrect
bundle exec brakeman -q --no-pager
bundle exec bundle-audit check --update

# ⚠️ --build-secret is not optional: --remote-only builds on fly's builder, so the private-registry
# token has to travel with the build or `npm ci` 401s and the deploy fails.
fly deploy --build-secret WEBAWESOME_NPM_TOKEN="$WEBAWESOME_NPM_TOKEN"   # app + worker
fly console

# Trigger a web rebuild (needs a running worker). ⚠️ Against production this ships a real deploy.
curl -i -X POST -H "Authorization: Bearer $API_TOKEN" "$KONA_API_URL/api/build"
```

**RuboCop** runs `rubocop-rails-omakase` — Rails' own ruleset, inherited verbatim in
`.rubocop.yml` with no rule overrides. It enables 50 of RuboCop's 609 cops (mostly Layout; no
Metrics, so nothing polices method or class length). ⚠️ **Keep it override-free**: taking the
omakase config *is* the decision not to have a house style. Disable a rule inline at the one site
that needs it rather than editing the config. `web/` uses the same ruleset.

CI runs RuboCop + Brakeman + bundler-audit, and the deploy job **won't run unless all pass**. If
Brakeman flags a verified false positive, add a checked-in `config/brakeman.ignore` rather than
weakening the code.

## Testing

RSpec request specs in `spec/requests/`, plus `spec/services/` and `spec/presenters/`. No DB or
fixtures — stub services with
`allow_any_instance_of(SomeService).to receive(:method).and_return(...)`. Specs assert the rendered
markup **and** the cache headers.

## Environment variables

Names only — see `.env.example`; never commit values. Production values are fly.io secrets (plus
Rails `config/credentials.yml.enc` + `master.key`).

- **Build credential**: `WEBAWESOME_NPM_TOKEN` — Web Awesome Pro npm auth for the admin UI, read by
  `.npmrc` at install time (not in `.env`, and not a fly secret — it's needed at *build* time, so it
  goes to fly via `--build-secret`).

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
  `CSP_ENFORCE` (any value enforces the owner-facing CSP; unset = Report-Only),
  `FONT_AWESOME_VERSION`, `WHOOP_REFERRAL_URL`, `TRAINERROAD_CALENDAR_URL`, `ANTHROPIC_API_KEY` +
  `ANTHROPIC_DESCRIPTION_MODEL` / `ANTHROPIC_CONTACT_SUBJECT_MODEL` (both default
  `claude-sonnet-5`), `PURPLEAIR_API_KEY`, `GOODSPEED_API_URL` (unset = the bay-conditions
  integration is off, and the water-temperature sentence and SF race-day bay readings are
  omitted), `LOCATION`, `TIME_ZONE`, `BLUESKY_PDS_URL` (⚠️ the
  Bluesky handle and app password are **not** env vars — they're set on the admin's Connected apps
  page and stored in Redis), `BUGSNAG_API_KEY` (production only), `ALLOWED_HOSTS`
  (comma-separated `Host` allowlist; production only, unset = all hosts accepted, so it's safe to
  deploy before setting it; `/up` is always exempt), `API_HOST` (the public API hostname; unset =
  every route drawn on every host, so dev/CI are unaffected — ⚠️ move `WHOOP_REDIRECT_URI` to the
  admin host before setting it), `R2_ACCOUNT_ID` + `R2_ACCESS_KEY_ID` +
  `R2_SECRET_ACCESS_KEY` + `R2_BUCKET` (⚠️ must be the bucket behind the web app's `IMAGE_HOST`;
  nothing validates that, and a mismatch 404s every image), `GITHUB_DISPATCH_TOKEN` +
  `GITHUB_REPOSITORY` (a fine-grained PAT with **Contents: Read and write**, plus the `owner/repo`
  slug), `PLAUSIBLE_API_KEY` + `PLAUSIBLE_SITE_ID` (⚠️ with either unset the pageviews widget
  collapses and `TrendingArticles` silently degrades to recency order — an INFO log is the only
  sign, and the result looks exactly like "working, nothing trending"), `VOYAGE_API_KEY` (unset =
  no embeddings, so the related-articles widget collapses), `MAPBOX_USERNAME` +
  `MAPBOX_SECRET_TOKEN` (a token with `tilesets:write` and `tilesets:read`; with either unset the
  Maps page says so and refuses uploads) plus `MAPBOX_ACCESS_TOKEN` (the ⚠️ **public** token: it
  renders server-side when there's no secret token, and it's what the Location page's browser map
  needs — unset, that page degrades to a coordinate form) and `MAPBOX_STYLE_URL` (the default style
  for new tracks; each track can override it, and the Location page ignores it),
  `REDIS_POOL_SIZE` (default 10; size it
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
