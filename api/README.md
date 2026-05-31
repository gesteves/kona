# kona-api

Rails app serving dynamic, embeddable markup for the otherwise-static Kona site.
Deployed to fly.io; the static site reaches it through a same-origin Netlify proxy
(`/api/*`) that caches responses on Netlify's edge.

## Endpoints

- `GET /up` — health check.
- `GET /activity-stats` — returns the monthly activity-stats markup (from Intervals.icu),
  ready to be inserted into the page by the site's `live-update` Stimulus controller.
  Serves permissive CORS (any origin) and caching headers
  (`Cache-Control: public, max-age=300, stale-while-revalidate=60`). The upstream
  Intervals.icu response is cached in Redis for 5 minutes; Font Awesome icon SVGs are
  cached in Redis (per version) as well.

## Configuration

Set these environment variables (e.g. as fly secrets):

- `REDIS_URL` — Redis connection (shared with the web app; `rediss://` for TLS).
- `ICU_ATHLETE_ID`, `ICU_API_KEY` — Intervals.icu credentials.
- `FONT_AWESOME_API_TOKEN` — Font Awesome API token.
- `FONT_AWESOME_VERSION` — (optional) Font Awesome version, defaults to `7.2.0`.

## Tests

```bash
bundle exec rspec
```
