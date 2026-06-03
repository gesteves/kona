# api/ — Kona widget API

Rails 8.1 API (Ruby 4.0.5) that serves small embeddable **HTML fragments** ("widgets")
— plus one JSON endpoint — for the static `web/` site. Deployed to **fly.io** as
`kona-api`; reached through the web app's same-origin Netlify proxy (`/api/*`).
Redis-backed caching, **no database**.

Minimal Rails: only ActiveModel + ActionController + ActionView are loaded (no
ActiveRecord / ActiveJob / ActionMailer / ActionCable). See the root
[`CLAUDE.md`](../CLAUDE.md) for the web↔api markup contract before changing any view.

## Endpoints

All `/api/*` widget responses are HTML fragments (`layout false`) with the cache
headers below. Edge TTL = how long Netlify serves a cached copy before revalidating.

| Method | Path | Action | Returns | Edge TTL |
|---|---|---|---|---|
| GET | `/up` | `rails/health#show` | health check | — |
| GET | `/api/activity-stats` | `activity_stats#show` | HTML (Intervals.icu totals) | 5 min |
| GET | `/api/weather/current` | `weather#current` | HTML (weather/AQI/pollen) | 5 min |
| GET | `/api/events/upcoming` | `events#upcoming` | HTML (upcoming races; featured event has inline race-day weather) | 1 hr |
| GET | `/api/articles/trending` | `articles#trending` | HTML (trending articles, ranked from Plausible) | 1 hr |
| GET | `/api/whoop` | `whoop#show` | HTML (sleep/recovery/strain) | 5 min |
| GET | `/api/plausible/pageviews/:id` | `plausible#pageviews` | HTML (pageview count by Contentful id) | 1 hr |
| POST | `/api/location` | `location#create` | sets Redis `location:current` (bearer-token gated) | — |
| POST | `/api/webhooks/contentful` | `webhooks#contentful` | syncs standard.site PDS records on publish/unpublish/delete (HMAC-gated); 204 | — |
| GET | `/api/standard-site` | `standard_site#show` | JSON `{did, publication_uri}` for the web build's verification markup | 1 hr |
| GET | `/whoop/auth` | `whoop_oauth#authorize` | redirect (HTTP-Basic gated) | — |
| GET | `/whoop/callback` | `whoop_oauth#callback` | OAuth token exchange | — |
| GET | `/` | redirect | 301 → main site | — |

## Architecture

- **Controllers** (`app/controllers/`): `Api::BaseController` (`layout false`, includes
  the `LiveWidget` concern); widget controllers fetch via a service, call
  `cache_widget(ttl:)`, then render an ERB fragment. Use `render_empty` (blank body)
  when data is unavailable — the site's `live-update` controller removes the placeholder
  (collapsing the widget) on an empty response, so prefer it over raising.
- **Services** (`app/services/`, base `ApplicationService`): one per external API —
  Intervals.icu, Apple WeatherKit (ES256 JWT), Google Maps / Air Quality / Pollen,
  PurpleAir, Whoop (OAuth2), TrainerRoad (iCal), Contentful (events/articles),
  Plausible, Font Awesome, Goodspeed (bay conditions), `StandardSite` (publishes the
  blog to the AT Protocol / Bluesky PDS as standard.site records — webhook-driven, plus
  the `standard_site:backfill` rake task in `lib/tasks/`). Read-through Redis cache via
  `cached_json(key, expires_in:)`; HTTParty with retries; `DeepOstruct` for dot-access.
- **Webhooks**: `Api::WebhooksController#contentful` receives Contentful publish/
  unpublish/delete events and keeps the standard.site PDS records in sync. Verified with
  Contentful's HMAC request-verification scheme (`ContentfulRequestVerification` concern,
  `CONTENTFUL_WEBHOOK_SECRET`). Synchronous (no job queue) within Contentful's 30s
  timeout; Contentful does **not** retry failures, so `rake standard_site:backfill` is
  the reconciliation/recovery path. Operations log at info level (`standard.site: …`).
- **Views** (`app/views/api/`) render raw HTML fragments; **helpers** (`app/helpers/`)
  were ported from the web app (weather, units, icons, markdown, time, etc.).
- **Caching** — `app/controllers/concerns/live_widget.rb`. `cache_widget(ttl:)` sets:
  - Browser: `Cache-Control: public, max-age=0, stale-while-revalidate=86400`
  - Edge: `Netlify-CDN-Cache-Control: public, durable, max-age=<ttl>, stale-while-revalidate=86400, stale-if-error=86400`
  ⚠️ The proxy forwards the edge header **only on 2xx** — only emit durable headers on
  successful, cacheable responses.
- **Errors** render as plain text via `lib/plain_text_exceptions.rb`. Unmatched paths are
  caught by the trailing `match "*unmatched"` route → `ApplicationController#route_not_found`
  (plain-text 404), instead of raising `ActionController::RoutingError`. This is what keeps
  scanner probes (`/api/.env`, `/wp-login.php`, …) to a single clean `status=404` lograge line
  rather than an exception backtrace. ⚠️ That catch-all **must stay the last route** in
  `routes.rb` or it will shadow everything below it.
- **Abuse mitigation** — `config/initializers/rack_attack.rb` (rack-attack middleware, wired
  up in `application.rb`). The origin is hit directly by vulnerability scanners, so it
  blocklists obvious probe paths (Fail2Ban: repeat offenders get a flat 403 and never reach
  routing) and throttles per-IP requests **to paths outside the known route prefixes**.
  ⚠️ All legitimate `/api/*` traffic shares the Netlify proxy's egress IPs, so do **not** add
  a blanket per-IP throttle — it would throttle real users. ⚠️ The throttle treats anything
  outside `RACK_ATTACK_KNOWN_PREFIXES` (`/up`, `/api`, `/whoop`, `/`) as a probe: **if you add
  a top-level route, add its prefix there** or it will be rate-limited. Disabled in the test
  env (`Rack::Attack.enabled`); counters live in the shared Redis (in-memory under test).
- **Redis** — global `$redis` from `config/initializers/redis.rb` (shares `REDIS_URL`
  with `web/`). No background jobs/workers; fly.toml runs a single `app` process.

## Commands

```bash
bin/dev                                              # local server (or bin/setup)
bundle exec rspec spec/requests/api/activity_stats_spec.rb   # single spec (fast)
bundle exec rspec                                    # full suite
bin/ci                                               # setup + full suite + security scan (CI)
bundle exec brakeman -q --no-pager                   # static security scan
bundle exec bundle-audit check --update              # dependency CVE scan
fly deploy                                           # deploy to fly.io
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
  `WHOOP_CLIENT_ID`, `WHOOP_CLIENT_SECRET`, `WHOOP_REDIRECT_URI`, `WHOOP_AUTH_USERNAME`,
  `WHOOP_AUTH_PASSWORD`, `GOOGLE_API_KEY`, `API_TOKEN` (bearer for `POST /api/location`),
  `WEATHERKIT_KEY_ID`, `WEATHERKIT_TEAM_ID`, `WEATHERKIT_SERVICE_ID`,
  `WEATHERKIT_PRIVATE_KEY` (base64 .p8), `CONTENTFUL_SPACE`, `CONTENTFUL_TOKEN`,
  `CONTENTFUL_WEBHOOK_SECRET` (64-char HMAC secret for the Contentful webhook), `SITE_URL`
  (public site root, for the standard.site publication `url`).
- **Optional**: `FONT_AWESOME_VERSION`, `WHOOP_REFERRAL_URL`, `TRAINERROAD_CALENDAR_URL`,
  `PURPLEAIR_API_KEY`, `LOCATION`, `TIME_ZONE`, `BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD`,
  `BLUESKY_PDS_URL` (standard.site publishing; no-ops when the handle/password are unset),
  `ALLOWED_HOSTS` (comma-separated `Host`-header allowlist; **production only**, enables
  host authorization. Unset = all hosts accepted, so it's safe to deploy before setting it,
  then activate by setting the fly secret. `/up` is always exempt. Never hardcode the host).

## Conventions & gates

- **Before committing/deploying** (non-negotiable): `bundle exec rspec` passes.
- Keep widget markup in sync with the matching `web/` placeholder (root `CLAUDE.md`).
- Font Awesome icons are fetched on demand by family/style/id (GraphQL) and cached per
  version in Redis — `icon_svg('classic', 'solid', 'eye')`. No allowlist needed here;
  any id a view references is fetched. (The `web/` app maintains its own separate
  allowlist for build-time icons.)

### Permissions

- Autonomous: read files, single-file `rspec`, local `bin/dev`.
- Ask first: `fly deploy`, secret changes, anything that flushes shared Redis,
  `git push`/commit, package installs.
