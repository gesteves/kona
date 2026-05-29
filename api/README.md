# kona-api

Rails app serving dynamic, embeddable markup for the otherwise-static Kona site.
Will sit behind CloudFront.

## Endpoints

- `GET /up` — health check.
- `GET /activity-stats` — returns the monthly activity-stats markup (from Intervals.icu),
  ready to be inserted into the page by the site's `live-update` Stimulus controller.
  Serves permissive CORS (any origin) and caching headers
  (`Cache-Control: public, max-age=300, stale-while-revalidate=3600`). The upstream
  Intervals.icu response is cached in Redis for 5 minutes; Font Awesome icon SVGs are
  cached in Redis (per version) as well.

## Configuration

Set these environment variables (e.g. as fly secrets):

- `REDIS_URL` — Redis connection (shared with the web app; `rediss://` for TLS).
- `ICU_ATHLETE_ID`, `ICU_API_KEY` — Intervals.icu credentials.
- `FONT_AWESOME_API_TOKEN` — Font Awesome API token.
- `FONT_AWESOME_VERSION` — (optional) Font Awesome version, defaults to `7.2.0`.
- `ACTIVITY_STATS_URL` — (optional) absolute URL the embedded markup should refetch from
  on `visibilitychange`. Defaults to the request's own scheme/host/path; set this when
  the public URL differs from the origin host (e.g. behind CloudFront).

## Tests

```bash
bundle exec rspec
```
