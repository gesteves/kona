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
| `api/` | Rails 8.1 API (Ruby 4.0.5). Serves small dynamic HTML fragments ("widgets") embedded into the static pages at runtime. | fly.io (`kona-api`) |
| `netlify.toml` (root) | Drives the Netlify build: `base = "web"`, `command = "bundle exec rake build"`, `publish = "build/"`. | — |

Both apps share the same Redis (`REDIS_URL`).

## How the two apps connect (request path)

1. Browser requests `/api/*` on the main site.
2. The Netlify Function `web/netlify/functions/api-proxy.mts` claims that path
   (`config.path = '/api/*'`) and proxies to `KONA_API_URL` (the fly.io origin).
3. The response is cached at Netlify's edge and reused by all viewers.

The proxy is deliberately strict:

- Forwards only the `accept` and `authorization` **request** headers (so every
  viewer's request is identical → one shared cache entry).
- Passes the origin's `Cache-Control` through verbatim (what the browser sees).
- Forwards `Netlify-CDN-Cache-Control` (the durable edge policy) **only on 2xx**, so
  errors/redirects are never durably pinned at the edge.
- Keys the edge cache on **path only** — no query params, no per-user vary.

⚠️ Don't break these: keep widget inputs in the **path** (IDs are path segments, not
query strings), and only emit durable edge headers on success responses.

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
- An **empty** response is an intentional no-op (the placeholder stays as rendered) —
  don't "fix" empty responses.

On the web side, placeholders are built with the `live_update_section` helper; the API
views build the matching outer element with `live_update_url`.

| Widget | web placeholder | api view | endpoint |
|---|---|---|---|
| Activity stats | `web/source/partials/placeholders/_stats.html.erb` | `api/app/views/api/activity_stats/show.html.erb` | `/api/activity-stats` |
| Whoop | `web/source/partials/placeholders/_whoop.html.erb` | `api/app/views/api/whoop/show.html.erb` | `/api/whoop` |
| Current weather | `web/source/partials/placeholders/_weather.html.erb` | `api/app/views/api/weather/current.html.erb` | `/api/weather/current` |
| Event weather | `web/source/partials/_event.html.erb` (inline `section.event__weather`) | `api/app/views/api/weather/event.html.erb` | `/api/weather/event/:id` |
| Pageviews | `web/source/partials/article/_full.html.erb` (inline `span`) | `api/app/views/api/plausible/pageviews.html.erb` | `/api/plausible/pageviews/:id` |

Shared CSS lives in `web/source/stylesheets/` (e.g. `stats`, `stats--has-four`,
`stats--has-three`, `weather`, `event__weather`).

⚠️ **When you change a widget's markup, class names, or DOM shape, edit the web
placeholder and the api view together** — and re-check the proxy constraints above.
