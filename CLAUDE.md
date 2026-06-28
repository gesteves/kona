# Kona — monorepo guide

This file covers the **monorepo shape and the contract between the two apps**. For
app-specific commands and conventions, read the nearest `CLAUDE.md`:

- [`web/CLAUDE.md`](web/CLAUDE.md) — Middleman static site (the blog).
- [`api/CLAUDE.md`](api/CLAUDE.md) — Rails API serving dynamic widgets.

Work on one app from inside its own directory; each has its own `Gemfile`,
`.env.example`, and test suite.

## Repo layout

| Path | What | Deploy |
|---|---|---|
| `web/` | Middleman 4 static site generator (Ruby 4.0.5). Builds the Contentful-powered blog and serves all static pages. | Netlify |
| `api/` | Rails 8.1 API (Ruby 4.0.5). Serves small dynamic HTML fragments ("widgets") embedded into the static pages at runtime, plus a Sidekiq `worker` process for background jobs (standard.site PDS sync). | fly.io (`kona-api`: `app` + `worker`) |
| `redis/` | Config (`fly.toml`) for the `kona-redis` fly app — the API's dedicated Redis (cache + Sidekiq queues). | fly.io (`kona-redis`) |
| `netlify.toml` (root) | Drives the Netlify build: `base = "web"`, `command = "bundle exec rake build"`, `publish = "build/"`. | — |

Each app has its own Redis, configured via its own `REDIS_URL`: `api/` uses the dedicated
`kona-redis` fly app (`redis/fly.toml`); `web/` uses a separate Upstash instance. The apps
keep distinct keyspaces, so there's no cross-app data sharing to preserve.

## Production domains — never hardcode

⚠️ **Never hardcode or mention the production hostnames anywhere in the code, including
comments, docs, examples, tests, and CI config.** This covers the public site host, the
API/admin host, and the fly.io origin host. They are environment-specific and must always
come from configuration:

- The API origin is read from `KONA_API_URL` (web build + `/api/*` proxy).
- The site URL is read from `URL` (web).
- The Whoop redirect URI is read from `WHOOP_REDIRECT_URI`; CI's deploy URL from the
  `API_PRODUCTION_URL` secret.

When an example or placeholder genuinely needs a host, use a generic stand-in like
`https://<your-app-host>/…` — never the real domain.

## How the two apps connect (request path)

1. Browser requests `/api/*` on the main site.
2. The Netlify Function `web/netlify/functions/api-proxy.mts` claims that path
   (`config.path = '/api/*'`) and proxies to `KONA_API_URL` (the fly.io origin).
3. The response is cached at Netlify's edge and reused by all viewers.

The proxy is deliberately strict:

- Forwards only the `accept` **request** header and **injects** a constant
  `Authorization: Bearer <API_TOKEN>` (the client's own `authorization` is dropped). The
  token is the same for every viewer, so every upstream request stays identical → one shared
  cache entry. It authenticates to the origin (the API requires it on every widget endpoint),
  so the widget origin is closed to the public; injecting it server-side keeps it out of the
  browser. ⚠️ `API_TOKEN` must be set in Netlify's env and **match the API's `API_TOKEN`** or
  every widget 401s and collapses site-wide.
- Passes the origin's `Cache-Control` through verbatim (what the browser sees).
- Forwards `Netlify-CDN-Cache-Control` (the durable edge policy) **only on 2xx**, so
  errors/redirects are never durably pinned at the edge.
- Keys the edge cache on **path only** — no query params, no per-user vary.

⚠️ Don't break these: keep widget inputs in the **path** (IDs are path segments, not
query strings), only emit durable edge headers on success responses, and keep the injected
`Authorization` constant (a per-request token would shatter the shared cache entry).

## The cross-app HTML contract (most important)

The API returns HTML fragments that **replace** placeholder elements in the static
site, so their markup must stay structurally in sync across the two apps.

Mechanism — `web/source/javascripts/stimulus/controllers/live_update_controller.js`:
it reads `data-live-update-url-value`, fetches the fragment (on connect when
`data-live-update-fetch-on-connect-value="true"`, and again on tab `visibilitychange`),
and on a **non-empty** response replaces the entire placeholder element with the API
fragment. Consequences:

- The API fragment's **outermost element must itself carry** the
  `data-controller="live-update"` + `data-live-update-url-value` attributes, or it stops
  refreshing after the first swap.
- Its tag, CSS class names, and DOM shape must match the placeholder.
- An **empty** response (or any non-2xx / network error) makes the controller **remove the
  placeholder**, collapsing the widget rather than leaving a stuck loading skeleton. So an
  empty body is the intentional "no data" signal — don't "fix" it by returning markup.

On the web side, placeholders are built with the `live_update_section` helper; the API
views build the matching outer element with `live_update_url`.

| Widget | web placeholder | api view | endpoint |
|---|---|---|---|
| Activity stats | `web/source/partials/placeholders/_stats.html.erb` | `api/app/views/api/activity_stats/show.html.erb` | `/api/activity-stats` |
| Whoop | `web/source/partials/placeholders/_whoop.html.erb` | `api/app/views/api/whoop/show.html.erb` | `/api/whoop` |
| Current weather | `web/source/partials/placeholders/_weather.html.erb` | `api/app/views/api/weather/current.html.erb` | `/api/weather/current` |
| Pageviews | `web/source/partials/article/_full.html.erb` (inline `span`) | `api/app/views/api/plausible/pageviews.html.erb` | `/api/plausible/pageviews/:id` |
| Upcoming races (race-day weather is inline in the featured event) | `web/source/partials/_upcoming_races.html.erb` | `api/app/views/api/events/upcoming.html.erb` | `/api/events/upcoming` |
| Trending articles | `web/source/partials/placeholders/_trending.html.erb` (the embedding page supplies the `url`: bare or `/exclude/:ids`) | `api/app/views/api/articles/trending.html.erb` | `/api/articles/trending` and `/api/articles/trending/exclude/:ids` |

Shared CSS lives in `web/source/stylesheets/` (e.g. `stats`, `stats--has-four`,
`stats--has-three`, `weather`, `event__weather`).

⚠️ **When you change a widget's markup, class names, or DOM shape, edit the web
placeholder and the api view together** — and re-check the proxy constraints above.
