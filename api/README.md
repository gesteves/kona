# kona-api

Rails app serving dynamic, embeddable markup for the otherwise-static [Kona](../README.md) site — weather, activity stats, Whoop, pageviews, etc. Deployed to fly.io; the [`web/`](../web/README.md) site reaches it through a same-origin Netlify proxy (`/api/*`) that caches responses on Netlify's edge.

## Setup

Copy `.env.example` to `.env` for local development; in production set these as fly secrets (`fly secrets set KEY=value`). See `.env.example` for the full list and notes.

### Required services

- **Redis** — caches upstream API responses (shared with the web app; `rediss://` for TLS). Set `REDIS_URL`.
- **Contentful** — looks up events and articles, and receives publish webhooks (to sync standard.site PDS records). Set `CONTENTFUL_SPACE`, `CONTENTFUL_TOKEN`, and `CONTENTFUL_WEBHOOK_SECRET` (HMAC secret verifying the webhook).
- **Font Awesome** — icons, fetched from the API and cached per version. Set `FONT_AWESOME_API_TOKEN`.
- **Intervals.icu** — activity stats. Set `ICU_ATHLETE_ID`, `ICU_API_KEY` (from the Intervals.icu settings page).
- **Google Maps** — geocodes the location and powers pollen/AQI lookups. Set `GOOGLE_API_KEY` for a project with the Geocoding, Time Zone, Maps Elevation, Air Quality, and Pollen APIs enabled.
- **WeatherKit** — current weather and forecast. Follow Apple's [WeatherKit REST setup](https://developer.apple.com/documentation/weatherkitrestapi/request_authentication_for_weatherkit_rest_api) and set `WEATHERKIT_KEY_ID`, `WEATHERKIT_TEAM_ID`, `WEATHERKIT_SERVICE_ID`, and `WEATHERKIT_PRIVATE_KEY` (the base64-encoded `.p8` key).
- **Whoop** — sleep/recovery/strain. Create a Whoop OAuth app and set `WHOOP_CLIENT_ID`, `WHOOP_CLIENT_SECRET`, and `WHOOP_REDIRECT_URI` (must match the app, e.g. `https://<your-app-host>/whoop/callback`). `GET /whoop/auth` is gated by HTTP Basic Auth (`WHOOP_AUTH_USERNAME`, `WHOOP_AUTH_PASSWORD`); visit it once to connect your account, after which tokens are stored in Redis.
- **API token** — set `API_TOKEN`, the bearer token required by `POST /api/location`.
- **Site URL** — set `SITE_URL`, the public site root (used for the `/` redirect and the standard.site publication URL).

### Optional services

- **Purple Air** — hyperlocal AQI from the nearest sensor (falls back to Google). Set `PURPLEAIR_API_KEY`.
- **TrainerRoad** — checks whether today is a rest day to adjust messaging. Set `TRAINERROAD_CALENDAR_URL` (the calendar-sync iCalendar feed).
- **Plausible** — per-article pageview counts and the trending-articles ranking. Set `PLAUSIBLE_API_KEY`, `PLAUSIBLE_SITE_ID`.
- **Location** — set `LOCATION` to a `"latitude,longitude"` pair, or leave it unset and POST the coordinates instead. `LOCATION` takes precedence; otherwise the value set via POST (stored in Redis) is used:

  ```bash
  curl -X POST https://<your-app-host>/api/location \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"latitude": 19.639133263373843, "longitude": -155.9967081931534}'
  ```

  A successful POST returns `204 No Content`. The api uses the stored location for its weather, AQI, and pollen lookups.
- **standard.site / Bluesky** — publishes posts to the AT Protocol PDS, webhook-driven (no-ops when unset). Set `BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD`, `BLUESKY_PDS_URL`.
- **Other**: `TIME_ZONE` (fallback timezone), `FONT_AWESOME_VERSION` (defaults to `7.2.0`), `WHOOP_REFERRAL_URL` (shown under the Whoop widget).

## Running locally

Requirements: Ruby.

1. Copy `.env.example` to `.env` and fill in the credentials above.
2. Install dependencies: `bundle install`.
3. Start the server: `bin/setup` (or `bin/dev`). It runs at `http://localhost:3000`.

## Common commands

| Command | Description |
| --- | --- |
| `bundle exec rspec` | Run the test suite |
| `bundle exec rspec spec/requests/api/activity_stats_spec.rb` | Run a single spec |
| `bin/ci` | Set up and run the full suite (as CI does) |
| `bundle exec rake standard_site:backfill` | Reconcile standard.site PDS records (recovery for missed webhooks) |
| `fly deploy` | Deploy to fly.io |
| `fly console` | Open a Rails console on the deployed app |

## Deployment

Deployed to fly.io as `kona-api`: `fly deploy`. Configure credentials with `fly secrets set KEY=value`.
