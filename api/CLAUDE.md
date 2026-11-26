# api/ — Kona widget API

Refer to the root [`CLAUDE.md`](../CLAUDE.md) for the markup contract between web and api before you
change a view, and for the rules for a comment that this app obeys.

Each feature keeps its rules in ⚠️ comments at the code that they guard. Read those comments before
you change a feature. This file holds only the rules that no one file shows.

Three topics are in `.claude/rules/` at the root, and each one loads with the files of its area:
`admin-ui.md`, `admin-social.md`, and `external-services.md`.

## The two hosts

The origin answers on **two host names**: the public host, which `API_HOST` names, and the admin
host. `config/routes.rb` keeps them apart, and its comment gives the rule for a new route.

## Security rules

Each rule below protects a boundary. Do not remove one, and do not make one weaker.

- A webhook controller does not use the bearer token at all: a sender cannot have our token, thus
  each one uses the HMAC method of its own service.
- `ApplicationService#download` reads a URL in fragments and stops at a byte limit. ⚠️ Use it for
  each body whose size another site decides, for example an `og:image`: the worker is a 512MB VM.
  It also refuses a URL that is not public, and it checks each redirect hop (`PublicAddress`): a page
  that another site names can send the app to the private network of fly.
- `OwnerFacing` sets `no-store`, `noindex`, and the CSP on each page for the owner. ⚠️ An admin
  action must never call `cache_widget`.
- ⚠️ `MAPBOX_SECRET_TOKEN` has `tilesets:write`. It must never reach a browser. The course-map
  images come through a proxy and never a redirect, and the location map uses `MAPBOX_ACCESS_TOKEN`
  only.
- ⚠️ **Never change the `ENCRYPTION_SALT` of a store**: the salt is part of the key, thus a new salt
  makes each stored secret unreadable and each card says "not connected".
- ⚠️ **Turnstile protects the JSON path only** (`request.format.json?`). Thus a POST from a script
  with no `Accept: application/json` does not do that check. We read this and **accepted** it: the
  widget needs JavaScript, and a check on both paths would stop the path with no JavaScript. The
  things that truly stop an attack are the honeypot, Akismet, which fails *closed* when it has a
  configuration, the length limits, and the throttle of 5 each hour on `X-Kona-Client-IP`. Do not
  remove one of those, and do not assume that Turnstile does that work. To close this gap, the path
  with no JavaScript needs a second factor also, for example a signed token with an expiry time that
  the server puts in the form.
- ⚠️ No Strava data goes to the LLM, and this integration shows no Strava data to another person.
  ⚠️ **The GPX comes from Intervals.icu, and never from Strava.** Intervals.icu refuses the GPX of
  an activity that came from Strava. Thus no Strava data goes into a map.

## Conventions

A view in `app/views/widgets/` renders a plain HTML fragment. Each **helper** in `app/helpers/` is a
format function or a selection function: each method takes its data as an argument, and no method
reads an instance variable of a controller. The state of a request is in a **presenter**
(`app/presenters/`): `WeatherSummaryPresenter` has the text and the rules of the weather widget, and
there are also `EventWeatherPresenter`, `UpcomingRacesPresenter`, and `WhoopPresenter`. Each
presenter takes its data as constructor keyword arguments. When the body of a controller needs a
helper, it calls that helper through the `helpers` object and it does not `include` the module.

A widget action gets its data from a service, calls `cache_widget(ttl:)`, and then renders an ERB
fragment. Use `render_empty` when the data is not available: the live-update controller of the site
then removes the placeholder. Use it and do not raise.

**Sidekiq** directly (`Sidekiq::Job`, and not ActiveJob), in `app/jobs/`. Each job inherits from
`ApplicationJob`, and its comment gives the retry rule.

⚠️ **No service uses a Redis `SCAN`.** The Sidekiq queues share this keyspace. A record that code
must list goes in one hash, as `contact:spam` and `maps:tracks` do.

⚠️ **An admin page that renders at each load makes no upstream request.** It reads its state from
Redis. A fetch would put an upstream failure in the path of the navigation.

⚠️ **Each call to another service inside an admin request needs its own timeout.** The request has
a 20-second rack-timeout. That timeout raises an exception that is not a `StandardError`, thus
`safely` does not catch it.

### The article rankings

⚠️ **The traffic of this site is too small for an A/B test.** Thus
each rule in `TrendingArticles` and `RelatedArticles` came from a measurement against the real data.
The `rake related:*` and `rake trending:*` reports are the only method to know if a change helped.

## The course-map renderer

⚠️ **This code makes no composite image on the server.** The Static Images API draws the track,
which is an `addlayer` over the tileset, and both pins, and it returns a complete PNG. Thus this
page needs no image library and no system package, and it uses `nokogiri` and `httparty` only. Do
not "improve" it into a local drawing: the worker is a 512MB VM.

## What Redis holds, and what a person must back up

That one instance holds three kinds of data, and only the first kind comes back by itself:

1. **The cache.** `ApplicationService#cached_json` writes each key, and `font-awesome:icon:*` and
   `blurhash:svg:*` are the two large families. Each key has a TTL.
2. **The locks and the idempotency records**, for example `build:trigger_lock`,
   `threads:published:*`, and `mastodon:status:*`, and the photos of a draft on the Social media
   page, `social:photo:*`. Each key has a TTL.
   ⚠️ `contentful:uploads`, the history of the media uploader, is the one exception: it has no TTL.
   `UploadLibrary#stage` prunes it, and it is not the only copy of anything.
3. **The durable records. This Redis is their only copy**: `contact:spam`, `maps:tracks`, each
   `*:credentials` hash, `whoop:<client id>:refresh_token`, `strava:subscription_id`, `location:current`,
   `standard_site:did`, and `standard_site:fingerprints`. **None of them has a TTL.**

⚠️ **`maxmemory-policy` is `volatile-lru` for that reason**, and `redis/fly.toml` gives the full
text. `noeviction` refuses each write at the cap, and that includes the credential write that a
reconnect needs. `volatile-lru` removes a key with a TTL only, thus it cannot touch group 3.
⚠️ `maxmemory` applies to the full instance and not to one logical database. Thus a second `db`
index is **not** a way to give the cache its own limit.

⚠️ **`rake redis:export` is the only backup.** Nothing runs it for you, and the fly volume has no
replica. It names each key of group 3 from a constant and it uses no SCAN. `rake redis:import`
reads the file back, and it refuses a key that already holds data unless you give `FORCE=1`.
⚠️ **The file holds each secret as Redis holds it, that is, encrypted with `secret_key_base`.** Thus
an import needs the same `RAILS_MASTER_KEY`. With a different key each card says "not connected"
and nothing raises. Keep the file off the repository.

## Tools and gates

There is one native dependency: **libvips** (`brew install vips`), which `ruby-vips` opens at the
boot of Rails. Thus `rspec` and `bin/dev` both fail without it, and `web/` needs the same library.

`.env.example` gives the name and the effect of each variable. Never commit a value.

**Before a commit and before a deploy** (this rule has no exception): `bundle exec rspec` passes.

**RuboCop** uses `rubocop-rails-omakase`, which is the ruleset of Rails. ⚠️ **Change no rule.** To
take the omakase configuration *is* the decision to have no house style. Turn a rule off in the code
at the one place that needs that, and do not edit the configuration.

CI runs RuboCop, Brakeman, bundler-audit, and `npm audit`, and the deploy job **operates only if
all four pass**. When Brakeman reports a problem that you checked and that is not true, add a
`config/brakeman.ignore` file to the repository and do not make the code weaker.

### Testing

A spec asserts the markup that the app rendered **and** the cache headers.

⚠️ **The specs need no Redis server.** `spec/support/mock_redis.rb` replaces `$redis` with
MockRedis, and it empties that store before each example. Sidekiq runs in the fake mode of
rspec-sidekiq, and Rack::Attack uses a memory store in the test environment. Thus a new Redis client
that does not go through `$redis` needs its own mock. CI has no Redis service, thus such a client
fails there.

### Permissions

- Permitted with no question: read a file, run `rspec` on one file, and run `bin/dev` on this
  machine.
- Ask first: `fly deploy`, a change to a secret, each command that flushes Redis, `git push`, a
  commit, and the installation of a package.
