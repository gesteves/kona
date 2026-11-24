# kona-api

Rails app serving dynamic, embeddable markup for the otherwise-static [Kona](../README.md) site — weather, activity stats, Whoop, pageviews, etc. Deployed to fly.io; the [`web/`](../web/README.md) site reaches it through a same-origin proxy (`/widgets/*`) in its Cloudflare Worker, which caches responses at the edge.

## Setup

Copy `.env.example` to `.env` for local development; in production set these as fly secrets (`fly secrets set KEY=value`). See `.env.example` for the full list and notes.

### Required services

- **Redis** — caches upstream API responses (shared with the web app; `rediss://` for TLS). Set `REDIS_URL`.
- **Contentful** — looks up events and articles, and receives publish webhooks (to sync standard.site PDS records). Set `CONTENTFUL_SPACE`, `CONTENTFUL_TOKEN`, and `CONTENTFUL_WEBHOOK_SECRET` (HMAC secret verifying the webhook).
- **Font Awesome** — icons, fetched from the API and cached per version. Set `FONT_AWESOME_API_TOKEN`.
- **Intervals.icu** — activity stats. Set `ICU_ATHLETE_ID`, `ICU_API_KEY` (from the Intervals.icu settings page).
- **Google Maps** — geocodes the location and powers pollen/AQI lookups. Set `GOOGLE_API_KEY` for a project with the Geocoding, Time Zone, Maps Elevation, Air Quality, and Pollen APIs enabled.
- **WeatherKit** — current weather and forecast. Follow Apple's [WeatherKit REST setup](https://developer.apple.com/documentation/weatherkitrestapi/request_authentication_for_weatherkit_rest_api) and set `WEATHERKIT_KEY_ID`, `WEATHERKIT_TEAM_ID`, `WEATHERKIT_SERVICE_ID`, and `WEATHERKIT_PRIVATE_KEY` (the base64-encoded `.p8` key).
- **Whoop** — sleep/recovery/strain. Create a Whoop OAuth app and set `WHOOP_CLIENT_ID`, `WHOOP_CLIENT_SECRET`, and `WHOOP_REDIRECT_URI` (must match the app, e.g. `https://<your-app-host>/whoop/callback`). The redirect URI must name the admin host. Connect the account with the Whoop card of the Connected apps page; the tokens then go into Redis.
- **API token** — set `API_TOKEN`, the bearer token required by `POST /api/location`, `POST /api/weight`, and `POST /api/ftp`.
- **Site URL** — set `SITE_URL`, the public site root (used for the `/` redirect and the standard.site publication URL).

### Optional services

- **Purple Air** — hyperlocal AQI from the nearest sensor (falls back to Google). Set `PURPLEAIR_API_KEY`.
- **TrainerRoad** — checks whether today is a rest day to adjust messaging. Connect the calendar-sync iCalendar feed on the admin's Connected apps page; there's no environment variable.
- **Plausible** — per-article pageview counts and the trending-articles ranking. Set `PLAUSIBLE_API_KEY`, `PLAUSIBLE_SITE_ID`.
- **Location** — set `LOCATION` to a `"latitude,longitude"` pair, or leave it unset and POST the coordinates instead. `LOCATION` takes precedence; otherwise the value set via POST (stored in Redis) is used:

  ```bash
  curl -X POST https://<your-app-host>/api/location \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"latitude": 19.639133263373843, "longitude": -155.9967081931534}'
  ```

  A successful POST returns `204 No Content`. The api uses the stored location for its weather, AQI, and pollen lookups.
- **Weight** — POST a body weight to write it to the Intervals.icu wellness record and to the Strava profile. `unit` is `kg` (default) or `lb`, and `date` defaults to today in the location's time zone. Strava needs the `profile:write` scope, so reconnect Strava on the Connected apps page if the token predates it:

  ```bash
  curl -X POST https://<your-app-host>/api/weight \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"weight": 160.2, "unit": "lb"}'
  ```

  A successful POST returns `204 No Content`; an invalid weight, unit, or date returns `422`.
- **FTP** — POST a cycling FTP in watts to write it to the Ride sport settings of Intervals.icu (both the FTP and the indoor FTP) and to the Strava profile. Strava needs the same `profile:write` scope as the weight:

  ```bash
  curl -X POST https://<your-app-host>/api/ftp \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"ftp": 265}'
  ```

  A successful POST returns `204 No Content`; an invalid FTP returns `422`.
- **standard.site / Bluesky** — publishes posts to the AT Protocol PDS, webhook-driven (no-ops until connected). Connect an account on the admin's Connected apps page; `BLUESKY_PDS_URL` optionally overrides the default PDS host.
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
| `bundle exec rspec spec/requests/widgets/activity_stats_spec.rb` | Run a single spec |
| `bin/ci` | Set up and run the full suite (as CI does) |
| `bundle exec rake standard_site:backfill` | Reconcile standard.site PDS records (recovery for missed webhooks) |
| `fly deploy` | Deploy to fly.io |
| `fly console` | Open a Rails console on the deployed app |

## Where things are

One row for each feature: where a request or an event comes in, and each file that it goes through. A name is a class, and its file is the same name in snake case:

- a controller is in `app/controllers/`, a job in `app/jobs/`, a service in `app/services/`, and a presenter in `app/presenters/`;
- a view folder is below `app/views/`;
- an admin JS name is a Stimulus controller in `app/javascript/controllers/` (`social` is `social_controller.js`), or a module in `app/javascript/lib/`.

| Feature | Comes in at | Jobs | Services | Presenter and views | Admin JS |
| --- | --- | --- | --- | --- | --- |
| Weather widget | `GET /widgets/weather/current` → `Widgets::WeatherController` | — | `Location`, `GoogleMaps`, `TimeZoneResolver`, `WeatherKit`, `AirQuality` (`PurpleAir`, then `GoogleAirQuality`), `GooglePollen`, `Goodspeed`, `Events`, `TrainerRoad` | `WeatherSummaryPresenter`, `WeatherHelper`, `widgets/weather`, `config/conditions.yml`, `config/beaufort.yml` | — |
| Upcoming races and race-day weather | `GET /widgets/events/upcoming` → `Widgets::EventsController` | — | `Events`, `RaceDayWeather` (`GoogleMaps`, `WeatherKit`, `GoogleAirQuality`, `Goodspeed`) | `UpcomingRacesPresenter`, `EventWeatherPresenter`, `EventsHelper`, `widgets/events` | — |
| Activity stats widget | `GET /widgets/activity-stats` → `Widgets::ActivityStatsController` | — | `Intervals` | `widgets/activity_stats` | — |
| Whoop widget | `GET /widgets/whoop` → `Widgets::WhoopController` | `WhoopTokenRefreshJob` (cron) | `Whoop`, `WhoopCredentials`, `TrainerRoad` | `WhoopPresenter`, `widgets/whoop` | — |
| Trending articles | `GET /widgets/articles/trending` → `Widgets::ArticlesController` | — | `TrendingArticles`, `Articles`, `ArticleRanking`, `Plausible`; `rake trending:*` uses `TrendingInspector` | `widgets/articles` | — |
| Pageviews of one article | `GET /widgets/plausible/pageviews/:id` → `Widgets::PlausibleController` | — | `Plausible`, `Articles`, `ArticleAttributes` | `widgets/plausible` | — |
| Related articles (JSON for the web build) | `GET /api/related` → `Api::RelatedController` | — | `RelatedArticles`, `ArticleIndex`, `ArticleTaxonomy`, `ArticleLinks`, `TaxonomyConcepts`, `ArticleRanking`, `Plausible`; `rake related:*` uses `RelatedInspector` | — | — |
| Strava activity description | `POST /webhooks/strava` → `Webhooks::StravaController`; the Whoop sync also starts it | `StravaActivityJob` → `ActivityDescriptionJob`; `StravaNameJob`; `RaceTrackJob` | `ActivityDescription::Generator` with `Composer`, `Weather`, `TrackWeather`, `WeatherSentence`, `Llm`, `RaceLeg` (all in `app/services/activity_description/`); `ActivityMatcher`, `Intervals`, `Strava`, `TrainerRoad`, `Whoop`, `WeatherKit`, `GoogleAirQuality`; prompts in `app/prompts/` | — | — |
| Whoop sync to Intervals.icu | `POST /webhooks/whoop` → `Webhooks::WhoopController` | `WhoopWebhookJob` | `WhoopWebhookProcessor`, `Whoop`, `Intervals` | — | — |
| Social posting | `/social` → `Admin::SocialController`, `Admin::SocialPhotosController`; `GET /api/social-photos/…` → `Api::SocialPhotosController` (Meta gets each photo there) | `BlueskyPostJob`, `MastodonPostJob`, `ThreadsPostJob` (parent `SocialPostJob`); `ThreadsTokenRefreshJob` (cron) | `SocialDraft`, `SocialDraftValidator`, `SocialPreview`, `SocialMentions`, `SocialText`, `Typography`, `MarkdownLinks`, `OpenGraph`, `SocialPhotos`, `PhotoBlob`, `PhotoCaption`, `AltText`, `Bluesky`, `Mastodon`, `Threads`, `AtProto` (in `concerns/`) | `SocialPresenter`, `admin/social` | `social`, `social_post`, `lib/social_mentions`, `lib/markdown_links`, `lib/typography`, `lib/picture_tiles` |
| standard.site sync | `POST /webhooks/contentful` → `Webhooks::ContentfulController`; `GET /api/standard-site` → `Api::StandardSiteController` | `StandardSiteSyncJob` | `StandardSite`, `AtProto`, `BlueskyCredentials`, `TaxonomyConcepts`, `ArticleAttributes`; `rake standard_site:backfill` | — | — |
| Image mirror and blurhash | `POST /webhooks/contentful` → `Webhooks::ContentfulController` | `AssetSyncJob`, `AssetBlurhashJob` | `AssetMirror`, `BlurhashPlaceholder`, `ImagesHelper`; `rake assets:backfill`, `rake blurhash:backfill` | — | — |
| Site build | `POST /webhooks/contentful`; `POST /api/build` → `Api::BuildController`; `POST /republish` → `Admin::RepublishController` | `SiteBuildJob` | — | `layouts/_republish_dialog` | `republish` |
| Contact form and spam | `POST /api/contact` → `Api::ContactController`; `/spam` → `Admin::SpamController` | `ContactMailJob` → `ContactDeliveryJob`; `ContactHamJob` (parent `ContactJob`) | `Turnstile`, `EmailDomain`, `SubmissionTime`, `Akismet`, `ContactModeration`, `ContactSubject`, `SpamQuarantine`, `Resend` | `SpamMessagePresenter`, `admin/spam` | — |
| Course maps | `/course-maps` → `Admin::CourseMapsController` | `MapTilesetJob`, `RaceTrackJob` | `GpxTrack`, `TrackLibrary`, `MapboxTileset`, `StaticMap` | `MapTrackPresenter`, `admin/course_maps` | `map_preview`, `linked_sides`, `file_submit`, `job_status` |
| Media uploader | `/contentful/uploads` → `Admin::ContentfulUploadsController`, `Admin::ContentfulUploadFilesController` | `ContentfulAssetJob` | `UploadLibrary`, `StagedUpload`, `ContentfulManagement`, `PhotoBlob`, `PhotoCaption`, `AltText` | `ContentfulUploadPresenter`, `admin/contentful_uploads` | `media_upload`, `job_status`, `lib/picture_tiles` |
| Connected apps | `/connected-apps` → `Admin::ConnectedAppsController`, and one controller for each app: `Admin::BlueskyController`, `MastodonController`, `ThreadsController`, `StravaController`, `WhoopController`, `TrainerRoadController` | the two token refresh jobs above | the service of each app and its `*Credentials` class (`EncryptedCredentials` in `concerns/`) | `ConnectedAppPresenter`, `admin/connected_apps`, `admin/bluesky`, `admin/mastodon`, `admin/trainer_road` | — |
| Location | `POST /api/location` → `Api::LocationController`; `/location` → `Admin::LocationController` | `LocationSyncJob` | `Location`, `LocationSync`, `LocationContext`, `GoogleMaps`, `GoogleGeocoder`, `TimeZoneResolver`, `Events`, `Intervals` | `LocationPresenter`, `admin/location` | `location_map` |
| Weight and FTP | `POST /api/weight` → `Api::WeightController`; `POST /api/ftp` → `Api::FtpController` | `IntervalsWeightJob`, `StravaWeightJob`, `IntervalsFtpJob`, `StravaFtpJob` | `Weight`, `Ftp`, `Intervals`, `Strava` | — | — |
| Icons (SVGs for the web build) | `POST /api/icons` → `Api::IconsController` | — | `FontAwesome`, `FontAwesomeClient`, `IconsHelper` | — | — |
| Owner sign-in | `/signin`, `/auth/google_oauth2/callback` → `SessionsController` | — | `Authentication` (in `app/controllers/concerns/`), `config/initializers/omniauth.rb` | `sessions` | — |

Shared plumbing that most rows use:

- `ApplicationService` — the base class of each API client: `cached_json`, `get_json` / `get_json!`, `download`.
- `UpstreamIsolation` (`safely`), `Retryable` (`with_retries`), `ParallelUpstreams`, `ErrorReporter` — what happens when an upstream fails.
- `LiveWidget` (in `app/controllers/concerns/`) — `cache_widget` and `render_empty`, the cache headers of each widget.
- `JsonHashStore`, `JsonRecordLibrary`, `ExpiringKeyStore`, `EncryptedCredentials` — the Redis stores.
- `AnthropicStructuredOutput` and `app/prompts/` — each call to Claude.
- `TokenAuthentication`, `Authentication`, `OwnerFacing` — the bearer token of a machine endpoint, and the session and headers of an admin page.
- `config/routes.rb` — which host serves which route.

## Deployment

Deployed to fly.io as `kona-api`: `fly deploy`. Configure credentials with `fly secrets set KEY=value`.
