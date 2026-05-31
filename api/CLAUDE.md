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
| GET | `/api/weather/event/:id` | `weather#event` | HTML (race-day weather by Contentful id) | 1 hr |
| GET | `/api/whoop` | `whoop#show` | HTML (sleep/recovery/strain) | 5 min |
| GET | `/api/plausible/pageviews/:id` | `plausible#pageviews` | HTML (pageview count by Contentful id) | 1 hr |
| POST | `/api/location` | `location#create` | sets Redis `location:current` (bearer-token gated) | — |
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
  Plausible, Font Awesome, Goodspeed (bay conditions). Read-through Redis cache via
  `cached_json(key, expires_in:)`; HTTParty with retries; `DeepOstruct` for dot-access.
- **Views** (`app/views/api/`) render raw HTML fragments; **helpers** (`app/helpers/`)
  were ported from the web app (weather, units, icons, markdown, time, etc.).
- **Caching** — `app/controllers/concerns/live_widget.rb`. `cache_widget(ttl:)` sets:
  - Browser: `Cache-Control: public, max-age=0, stale-while-revalidate=86400`
  - Edge: `Netlify-CDN-Cache-Control: public, durable, max-age=<ttl>, stale-while-revalidate=86400, stale-if-error=86400`
  ⚠️ The proxy forwards the edge header **only on 2xx** — only emit durable headers on
  successful, cacheable responses.
- **Errors** render as plain text via `lib/plain_text_exceptions.rb`.
- **Redis** — global `$redis` from `config/initializers/redis.rb` (shares `REDIS_URL`
  with `web/`). No background jobs/workers; fly.toml runs a single `app` process.

## Commands

```bash
bin/dev                                              # local server (or bin/setup)
bundle exec rspec spec/requests/api/activity_stats_spec.rb   # single spec (fast)
bundle exec rspec                                    # full suite
bin/ci                                               # setup + full suite (CI)
fly deploy                                           # deploy to fly.io
fly console                                          # production console
```

No Rubocop / linter is configured. `.rspec` requires `spec_helper`.

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
  `WEATHERKIT_PRIVATE_KEY` (base64 .p8), `CONTENTFUL_SPACE`, `CONTENTFUL_TOKEN`.
- **Optional**: `FONT_AWESOME_VERSION`, `WHOOP_REFERRAL_URL`, `TRAINERROAD_CALENDAR_URL`,
  `PURPLEAIR_API_KEY`, `LOCATION`, `TIME_ZONE`.

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
