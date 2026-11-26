---
paths:
  - "api/app/controllers/webhooks/**"
  - "api/app/controllers/admin/{connected_apps,strava,whoop,threads,bluesky,mastodon,trainer_road}_controller.rb"
  - "api/app/views/admin/connected_apps/**"
  - "api/app/services/activity/{strava,whoop,trainer_road}*.rb"
  - "api/app/services/social/{bluesky,mastodon,threads}*.rb"
  - "api/app/jobs/{strava,whoop,threads}_*.rb"
  - "api/lib/tasks/strava.rake"
  - "api/spec/requests/webhooks/**"
---

# The settings of the external services

These settings are outside this repo, in the dashboard of each service.

- Set the Contentful webhook to a publish, an unpublish, and a delete of an **Entry and an Asset**,
  thus a change to an image also starts a build. Do **not** include an automatic save. ⚠️ Contentful
  does **not** send a delivery again. `rake standard_site:backfill`, `rake assets:backfill`, and
  `rake blurhash:backfill` are the reconciliation paths.
- Register the Whoop webhook URL with **Model Version V2** in the Whoop dashboard.
  `WhoopWebhookProcessor` writes the custom wellness fields `WhoopStrain`, `WhoopSleepPerformance`,
  and `WhoopRecovery`, and the activity field `WhoopWorkoutStrain`. ⚠️ All four must exist in
  Intervals.icu at Settings → Custom Fields. Without one of them, the code writes a 422 to the log
  and does no more.
- ⚠️ **The Authorization Callback Domain of the Strava app must be the admin host.** Strava checks
  the host only, and an app has ONE domain. Thus use a second Strava app with `localhost` for
  local work.
- **`rake strava:subscribe` makes the subscription**, or finds the one that exists, and stores its id
  at `strava:subscription_id`. ⚠️ Strava permits ONE subscription for each app, and it GETs the
  callback with a challenge before it answers. Thus deploy `STRAVA_WEBHOOK_VERIFY_TOKEN` first. With
  no stored id, the controller refuses each event, thus run the task again after a Redis flush.
- The Meta dashboard must list the Threads callback URL of the admin host, and it must permit each
  scope in `Threads::SCOPES`. ⚠️ A new scope needs a new authorization by the owner.
  ⚠️ **Meta gives no endpoint to revoke a token**, thus `disconnect!` is a local removal only. To
  end the access at Meta, the owner must also remove the app at Threads → Settings → Website
  permissions.
- Bluesky, Mastodon, and TrainerRoad have no environment variable. The owner connects each one on
  the Connected apps page, and Redis holds the only copy. ⚠️ To flush Redis costs a new connection.
