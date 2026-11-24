# api/ — Kona widget API

Refer to the root [`CLAUDE.md`](../CLAUDE.md) for the markup contract between web and api before you
change a view, and for the rules for a comment that this app obeys.

Each feature keeps its rules in ⚠️ comments at the code that they guard. Read those comments before
you change a feature. This file holds only the rules that no one file shows.

## The two hosts

The origin answers on **two host names**, and `config/routes.rb` keeps them apart. `API_HOST` names
the public host, and Rails draws each route for the owner off the *other* host, which is the admin
host. Thus the public host serves only `/up`, `/widgets/*`, `/api/*`, and `/webhooks/*`. ⚠️ **Put each new route for
the owner in that `constraints` block.** The SBFM skip rule of the zone covers the public host and
not the admin host. Thus a route outside that block is available on the public host, with Super Bot
Fight Mode off.
`spec/requests/host_constraints_spec.rb` tests both directions.

## Security rules

Each rule below protects a boundary. Do not remove one, and do not make one weaker.

- A webhook controller does not use the bearer token at all: a sender cannot have our token, thus
  each one uses the HMAC method of its own service. ⚠️ **Strava does not sign an event.** Thus the
  controller accepts only our `subscription_id` and the `owner_id` of the connected athlete, and it
  uses only the id and the time of the event. A forged event can then only start the description of
  one of our own activities again.
- `ApplicationService#download` reads a URL in fragments and stops at a byte limit. ⚠️ Use it for
  each body whose size another site decides, for example an `og:image`: the worker is a 512MB VM.
  It also refuses a URL that is not public, and it checks each redirect hop (`PublicAddress`): a page
  that another site names can send the app to the private network of fly.
- ⚠️ **The blocklist must not use an IP. Never ban by IP.** Some probe paths are available through
  the public `/widgets/*` proxy, and each correct widget request shares the egress IPs of that
  proxy. Thus a ban by IP gives a 403 to the widgets of each visitor at the same moment. For the same
  reason, use no throttle for each IP.
- `OwnerFacing` sets `no-store`, `noindex`, and the CSP on each page for the owner. ⚠️ An admin
  action must never call `cache_widget`.
- ⚠️ **The cards of the Spam page are the only input from an attacker that this app renders as HTML
  with no filter.** The default escape of ERB is the full defense: use no `raw`, no `html_safe`, and
  no `simple_format` on a message field.
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
- ⚠️ **The contact jobs do not use the 24-hour window.** They inherit from `ContactJob`, which sets
  `retry_for: nil`, thus Sidekiq uses its default of 25 attempts, approximately 21 days. A contact
  message must never go away, and the subject line is the only step that can fail and be skipped.
  A message that Akismet or `ContactModeration` marks goes to the quarantine (`SpamQuarantine`). The
  app does not delete it: the owner sends it or deletes it on the Spam page.
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
`ApplicationJob`, a plain parent class that holds the shared `retry_for: 24.hours`: Sidekiq waits
the usual time between two attempts, then puts the job in the Dead set 24 hours after its first
failure. Each job takes plain strings as its arguments, and you can do each job more than one time.
Thus that shared window is safe. ⚠️ The contact jobs are the exception: they inherit from
`ContactJob`, which uses the default retries of Sidekiq.

⚠️ **Plausible permits 600 calls each hour**, and `cached_json` limits each different query body to
one call for its 5-minute TTL. Thus the number of *different queries* is important, and the number of
requests is not. For that reason each `Plausible` aggregate is **one query for the full site**, and
never one query for each article. A query for each article would make one key for each article, and
the number of calls would then grow with the number of articles and go past the limit. **Do not add
a query for each article, and do the calculation again before you make either TTL shorter.**

⚠️ **No service uses a Redis `SCAN`.** The Sidekiq queues share this keyspace. A record that code
must list goes in one hash, as `contact:spam` and `maps:tracks` do.

⚠️ **An admin page that renders at each load makes no upstream request.** It reads its state from
Redis. A fetch would put an upstream failure in the path of the navigation.

⚠️ **Each call to another service inside an admin request needs its own timeout.** The request has
a 20-second rack-timeout. That timeout raises an exception that is not a `StandardError`, thus
`safely` does not catch it.

### The article rankings

⚠️ **No A/B test can operate at the traffic of this site**, approximately 23 visitors each day. Thus
each rule in `TrendingArticles` and `RelatedArticles` came from a measurement against the real data.
The `rake related:*` and `rake trending:*` reports are the only method to know if a change helped.

## The admin UI

⚠️ **Each user-facing word of the admin is in `config/locales/en.yml`, below `en.admin.*`.**
A view uses the lazy key of its own path (`t(".title")` in `admin/spam/index.html.erb` reads
`en.admin.spam.index.title`), and a file below `app/views/layouts/` uses the full key, because it
renders from more than one page. A presenter, a controller, and a helper use the full key, and a
presenter calls `I18n.t` and not the bare `t`. **Write no user-facing word in an ERB file, in a Ruby
method, or in a JS file.**

- ⚠️ **This is for ONE place for the copy, and not for a second language.** A spec asserts
  `I18n.t("admin.…")` and never the words, thus a change to a word breaks no spec. That is the
  purpose. `spec/support/translation_helpers.rb` has `t_before`, for a message where an
  interpolated value — a date, a count — is the thing that the spec must prove.
- ⚠️ **Only the WORDS move.** An icon id, a path, a CSS class, a `data-` hook, a DOM id, and a Web
  Awesome `variant` stay in the code. `ConnectedAppPresenter#status_variant` stays beside
  `#status_label`, which left.
- ⚠️ **A DOM id must never come from a translated word.** The caption of a nav group takes its id
  from the `:key` of that group, and `aria-labelledby` points at it. An id from the label would
  move when a person changes a word.
- ⚠️ **Each key is a COMPLETE sentence.** Do not join one from a label and a fragment. Where a part
  is optional — a date, the "with the Bluesky handles" clause — there are **two keys** and the code
  selects one. `admin.social.errors.*` has a `single` form and a `numbered` form for that reason.
- ⚠️ **The widget views and the widget presenters are NOT part of this rule.** `WeatherSummaryPresenter`,
  `WhoopPresenter`, `EventWeatherPresenter`, and `UpcomingRacesPresenter` render public-site copy,
  which is part of the markup contract with `web/` and which the edge caches. Leave it in the code.
- **The words that a Stimulus controller renders come from the same file.** JavaScript cannot read
  `en.yml`, thus `AdminHelper#admin_i18n_data(scope, **nested)` writes the subtree into a
  `data-admin-i18n` attribute and `app/javascript/lib/i18n.js` reads it, does the `one`/`other`
  choice, and puts each `%{name}` value in.

**The stack: Turbo, Stimulus, and Web Awesome, and the server renders each page.** There is no SPA
framework and no separate front-end app, on purpose, and not because the plans are small: a maps UI,
a daily dashboard, and, later, a replacement for Contentful all belong here. Web Awesome already has
the admin components that those need, and one set of components across `web/` and `api/` is what
keeps the design system as one. When one screen truly needs state in the browser, add it as an
**island**: install the npm package, import it in `app/javascript/admin.js`, and start it from the
`connect()` of a Stimulus controller. The pipeline accepts that with no change.

**The styles are Sass**, with one BEM block in each partial below `app/javascript/styles/`, and
`admin.scss` imports them.

- ⚠️ **Do not use `<wa-icon>`.** It finds each icon through a base path or a Font Awesome kit code,
  and neither one is in this configuration. The npm package has no icon file, thus each icon is
  empty and it gives no message. Use `icon_svg(family, style, id)`, and **always with `raw`**: it
  returns a plain String, and without `raw` ERB escapes the markup and the page shows it as text.
  For an icon in a slot of a component (`start` or `end` on `<wa-button>`, and `icon` on
  `<wa-callout>`), use `slotted_icon_svg(family, style, id, slot:)`, which returns a safe buffer and
  needs no `raw`.
- ⚠️ **ARIA on a `wa-*` host does not reach the element in its shadow root.** `<wa-button>` renders
  its own `<button>` or `<a>`, and it sends `href`, `target`, `rel`, and `type` to that element but
  no ARIA. `icon_svg` also marks each SVG `aria-hidden`. Thus an `aria-label` or an `aria-current`
  on the host does nothing for a screen reader. Put the name or the state in the **content of the
  slot**, in a `wa-visually-hidden` span. The button in the header and the current item of the nav
  both do that. Turbo is different: it *does* go into a shadow root and out of it. It finds the
  anchor in a `wa-button` through the composed path of the click, and it then finds
  `data-turbo="false"` on the host. Thus a `<wa-button href>` navigates with Drive, as a plain link
  does.
- ⚠️ **A same-origin URL that redirects to a different origin needs `data-turbo="false"`.** Turbo
  Drive cannot follow that redirect. It fails with no message, and the click appears to do nothing.
  Today that is the Google sign-in form, the Mastodon instance form, and each Connect button of
  Connected apps.

**Use a Web Awesome component in place of a native element wherever one exists.** Use its layout
utilities (`wa-stack`, `wa-cluster`, `wa-grid`, `wa-gap-*`, and `wa-visually-hidden`) and its design
tokens (`--wa-space-*`, `--wa-color-*`, and `--wa-form-control-*`) in place of CSS that a person
writes. In practice that means **no** `button_to`, which writes a native `<button>`. Use `form_with`
around a `<wa-button type="submit">`. The button of Web Awesome is part of its form
(`formAssociated = true`), thus it submits that form as a native button does, and this includes the
CSRF token and `_method`. A plain `<button` in the server HTML means that one came back into the
code, and two request specs check that there is none.

Use Sass here for what is truly ours: the layout of one page, the brand colors, and a border that
the component does not draw. A rule that repeats the appearance of a component — its corner radius,
its hover color, its focus ring, or the height of a control — means that a person did not use the
API of that component. Use `appearance`, `variant`, or `size` first, then its CSS custom properties,
then `::part()`, and write your own rule last. The same applies to the markup: when a `wa-*` element
appears to have no method for something, read its documentation before you make your own code. More
than one difficult part here is documented behavior: the navigation slot of `<wa-page>`, the form
association, and `::part(base)`.

⚠️ **The package has its own documentation. Read it, and do not use an API from memory.** That
documentation is the source of the examples of the vendor, and its version is the version that you
installed:

- The **`webawesome` skill** is available in this environment. Use it for the API of a component,
  that is, its attributes, its slots, its parts, and its events, and for the list of the utilities
  and the tokens.
- Both skills are on the disk at `node_modules/@web.awesome.me/webawesome-pro/dist/skills/`. There is
  one `webawesome/references/components/<name>.md` for each component, and `webawesome-design/`
  covers the layout and the theme.
- When neither one has the answer, read the source and the styles of the component
  (`dist/components/<name>/` and `dist/chunks/*.js`). That is the only place with the shadow-DOM
  behavior above.

**Each admin page uses the same three parts.** Keep a new page the same:

- `<main>` is a `wa-stack wa-gap-xl`. Thus a page sets no margin between its blocks.
- `layouts/_page_header` makes the tab title, the back link, the `<h1>`, and the lead text.
- A list of items is an `admin-card-list plain-list wa-grid wa-gap-m` of `admin-card` cards. Refer to
  `_admin-card.scss`.

A form is a `wa-stack wa-gap-l`, and its buttons go in a `wa-cluster wa-gap-s` at its end. Each
button and each callout has an icon. A delete button on a card is `neutral`, and red is for the
confirm button in its dialog only, because the brand color is red.

**The messages.** ⚠️ **Each message that an action gives is a TOAST, and there is no flash callout.**

⚠️ **A `<wa-callout>` that stays on a page is a different thing, and it is correct.** An empty state
(Spam, Course maps), a warning about the configuration (Location, Course maps), and the error of one
card or one row (Connected apps, a failed track) are all true at each load of that page. A toast goes
away after some seconds and never comes back, thus **do not change one of those into a toast**.

### The Social media page

**Social media** (`/social`) drafts a post, or a **thread** of them, for Bluesky, Mastodon, and
Threads, now or at a date and a time.

- **The link is a plain `wa-input type="url"`, and there is NO list of the entries.** The owner
  pastes a link. ⚠️ **Do not add a picker of the articles back.** The card of a post comes from the
  `og:` tags of whatever page the link names, thus a link to another site needs no more code, and a
  list would cover this one site only.
- ⚠️ **The browser cannot read the page itself.** The CSP of the admin has `connect-src :self`,
  and another host sends no CORS header. Thus this app reads it. **Do not try to move this into
  the browser.**
- ⚠️ **The picture is a proxy of ours, and never the `og:image` itself**, because `img-src` is
  `:self`. `GET /social/preview/image` sends it, exactly as the Course maps page proxies a Mapbox
  render.
- ⚠️ **The parameter of that proxy is the URL of the PAGE, and not of the picture.** Thus a caller
  cannot name any URL for this app to get: the picture is always the one that the `og:` tags of
  that page name.
- ⚠️ **Do not add a Bluesky threadgate or postgate control.** The owner read those options and
  refused them. This page has no control for one network alone.
- ⚠️ **The danger of a mention is not a mention that does nothing, it is a mention that tags a
  STRANGER.** `@tony.bsky.social` is correct at Bluesky, and Threads reads `@tony` in it and tags
  whoever holds that name. Nothing reports that.
- ⚠️ **The map of the mentions is part of the DRAFT, and nothing stores it.** It goes out with the
  form and it is gone after the post. There is no directory, no Redis key, and no admin page: a
  handle that a store holds goes out of date, and a name is needed for one draft only.
- ⚠️ **A thread that fails part of the way through leaves the posts above it published**, on that
  network only. This is accepted: the alternative is to delete posts that are already public, and a
  reader may have replied to one. Each other network has its own chain and is unaffected.

### The course-map renderer

⚠️ **This code makes no composite image on the server.** The Static Images API draws the track,
which is an `addlayer` over the tileset, and both pins, and it returns a complete PNG. Thus this
page needs no image library and no system package, and it uses `nokogiri` and `httparty` only. Do
not "improve" it into a local drawing: the 512MB VM ran out of memory in the past.

## Settings outside this repo

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

CI runs RuboCop, Brakeman, and bundler-audit, and the deploy job **operates only if all three
pass**. When Brakeman reports a problem that you checked and that is not true, add a
`config/brakeman.ignore` file to the repository and do not make the code weaker.

### Testing

A spec asserts the markup that the app rendered **and** the cache headers.

⚠️ **The specs need no Redis server.** `spec/support/mock_redis.rb` replaces `$redis` with
MockRedis, and it empties that store before each example. Sidekiq runs in the fake mode of
rspec-sidekiq, and Rack::Attack uses a memory store in the test environment. Thus a new Redis client
that does not go through `$redis` needs its own mock. CI has no Redis service, thus such a client
fails there.

⚠️ **An admin spec asserts `I18n.t("admin.…")`, and never the words.** Each user-facing word of the
admin is in `config/locales/en.yml`, thus a change to the copy must break no spec. Refer to **The
admin UI**.

- A literal stays only where that literal is the thing that the spec proves: a path, a piece of
  markup, `<button`, a secret that must be absent, and the escaped `<script>` payload of the spam
  page.
- ⚠️ **A body assertion escapes the translation** (`ERB::Util.html_escape(I18n.t(…))`), because ERB
  escaped the apostrophe of "didn't". A `flash` assertion compares the raw string.
- `t_before(key, :placeholder)` in `spec/support/translation_helpers.rb` gives the words before an
  interpolation. Use it where the value — a date, a count — is behaviour that the spec must prove
  and the words around it are copy.
- ⚠️ **Never assert that a translation equals its own key.** Such a spec proves nothing and it puts
  the copy back in two files.

### Permissions

- Permitted with no question: read a file, run `rspec` on one file, and run `bin/dev` on this
  machine.
- Ask first: `fly deploy`, a change to a secret, each command that flushes Redis, `git push`, a
  commit, and the installation of a package.
