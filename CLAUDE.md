# Kona — monorepo guide

This file gives the **shape of the monorepo and the contract between the two apps**. For the
commands and the rules of one app, read the nearest `CLAUDE.md`:

- [`web/CLAUDE.md`](web/CLAUDE.md) — Middleman static site (the blog).
- [`api/CLAUDE.md`](api/CLAUDE.md) — Rails API serving dynamic widgets.
- [`utilities/contentful/CLAUDE.md`](utilities/contentful/CLAUDE.md) — Contentful migrations + taxonomy.

Work on one app from its own directory. Each app has its own `Gemfile`, its own `.env.example`, and
its own test suite.

## Repo layout

| Path | What | Deploy |
|---|---|---|
| `web/` | The Middleman 4 static site (Ruby 4.0.6). It builds the blog, whose content comes from Contentful. | Cloudflare Workers (`kona-web`) |
| `api/` | The Rails 8.1 API (Ruby 4.0.6). It serves the HTML "widget" fragments that go into the static pages at run time. It also has a Sidekiq `worker` process and an admin UI for the owner, at the root of the admin host. | fly.io (`kona-api`: `app` and `worker`), behind Cloudflare |
| `redis/` | The `fly.toml` of `kona-redis`, which is the Redis of the API: the cache and the Sidekiq queues. | fly.io |
| `utilities/` | The local-only tools. They never go to production. Refer to the text below. | — |

Each app has its own Redis, through its own `REDIS_URL`: `api/` uses `kona-redis`, and `web/` uses a
different Upstash instance. The two keyspaces are separate, and they share no data.

There is also a **Cloudflare R2 bucket** that holds a copy of each Contentful image asset. Its own
custom domain in the zone serves it. There is no configuration for it in the repo: it is in the
dashboard, and the api fills it. Refer to **The image mirror**.

### `utilities/` — local-only tools

⚠️ **The purpose of this directory is that nothing here goes to production.** `web.yml` and
`api.yml` have a path filter on `web/**` and on `api/**`. Thus a change below `utilities/` builds
nothing, deploys nothing, and never starts the `Cache-Tag: site` edge purge of the Web deploy. **Do
not make `web/` or `api/` depend on a file here**, at build time or at request time.
`.github/workflows/utilities.yml` runs the checks that exist, which today are the known-correct AQI
values of `utilities/aqi-map/`, and it deploys nothing.

- **`utilities/contentful/`** — the content migrations and the SKOS taxonomy toolkit.
- **`utilities/aqi-map/`** — a Sinatra app of its own. It serves one local page: a Mapbox map of the
  PurpleAir readings of a time in the past, for a screenshot that becomes the cover image of a post.
  It is a first version, and **it must not go to production**: it binds `127.0.0.1` and it proxies a
  PurpleAir key with no authentication of its own.
  ⚠️ It has a **copy** of the EPA correction and of the AQI conversion from
  `api/app/services/purple_air.rb`, because `utilities/` must not depend on `api/`. Thus a
  correction there does not reach this copy. The copy is in `utilities/aqi-map/lib/epa_aqi.rb`
  alone, thus you can compare the two files directly. `spec/epa_aqi_check.rb` tests it against
  known-correct values, which come from the **published equation** and not from either copy of the
  code. Thus one error in both copies cannot pass. `utilities.yml` runs that check.

## Local development

There are two commands, and **the command that you run selects the API**. There is no flag for
that, on purpose:

```bash
overmind start                    # web :4567 + api :3000 + the api's esbuild watch, site → the local api
cd web && bundle exec middleman   # web only, site → the deployed api
```

You need `overmind` (`brew install overmind`, which also installs tmux). It reads `Procfile.dev`
and `.overmind.env`, and each child process gets the `KONA_API_URL` and the `SITE_URL` of that
second file. dotenv never replaces a variable that has a value, and that is the full mechanism. It
is also why the plain `middleman` command still reaches production, from `web/.env`.
`overmind restart web` restarts one process. `overmind connect api` gives a true TTY, thus
`binding.break` works.

⚠️ **Sidekiq starts with the other processes**: `overmind start` runs `web`, `api`, `js`, and
`worker`. The worker was optional, because no widget endpoint adds a job to a queue. But the Course
maps page of the admin changed that: a GPX file that a user uploads stays at "Processing" until
`MapTilesetJob` publishes it. That page says so when it finds no Sidekiq process, but you must not
need that message on your own machine.

The `js` process is esbuild, which watches the admin bundle of the api. It applies to the admin
pages of the api and to `/signin` only. The widgets and the site do not use it. ⚠️ Those pages raise
`Propshaft::MissingAssetError` when nothing made the bundle. Thus run `npm run build` in `api/` one
time after a new clone. `bin/setup` does that.

The ports: 4567 for Middleman, 3000 for Rails, 8787 for `wrangler dev`, and 6379 for Redis. The api
writes its log to `api/log/development.log`, and **not** to its overmind pane.

Two conditions look like a problem and are not:

- `overmind kill` can leave `.overmind.sock`, and the next `overmind start` then stops with "it
  looks like Overmind is already running". Delete that socket. Ctrl-C and `overmind quit` both end
  the session correctly.
- A group of `ActionController::RoutingError` messages at the **first** page load of the api. They
  go away at the next load. `routes.rb` ends with a `*unmatched` catch-all, thus nothing can raise
  that error after Rails loads the routes. Those messages mean that the route set was empty for a
  short time. Rails in development has `enable_reloading = true` and `eager_load = false`, thus the
  first request draws the routes again while the two other Puma threads already answer the five
  widget requests of the page. It is a race in the reload of the development mode, and it is not the
  proxy.

⚠️ `Procfile.dev` sets `PORT=3000` for the api. Overmind gives each process a `PORT` in the Heroku
style: 5000, then 5100, and so on. `api/config/puma.rb` reads it. Thus without that line, the api
starts on 5100 and each widget gets a 502 against a `KONA_API_URL` that looks correct.

⚠️ `/widgets/*` and `POST /api/contact` reach `middleman server` through
`web/lib/utils/dev_api_proxy.rb`, a Rack middleware for development only. The static site has no
page at those paths, thus without that middleware each widget goes away on your own machine. It is
**not** a copy of `web/src/api-proxy.ts` and it must not become one: the rules in that file make one
shared edge cache entry safe for many viewers, and there is no edge here. `/pa/*` and the OG cards
have no proxy, on purpose: they need `wrangler dev` (refer to [`web/CLAUDE.md`](web/CLAUDE.md)).

## Duplicated across the two apps

The aqi-map copy above is not the only one: five helpers are in both `api/` and `web/`, because they
render markup that goes onto the **same page**. The static build renders an article, and the api
renders the same summary text again, into the trending fragment and the related fragment that
replace parts of that page. A difference between the two changes the typography, or the behavior of
a link, in the middle of a page:

| Logic | api | web |
|---|---|---|
| `markdown_to_html` + `smartypants` | `helpers/markdown_helper.rb` | `helpers/markdown_helpers.rb` |
| `clock_icon_svg` | `helpers/icons_helper.rb` | `helpers/icon_helpers.rb` |
| `article_permalink_timestamp` | `helpers/articles_helper.rb` | `helpers/article_helpers.rb` |
| Canonical article path | `services/article_attributes.rb` | `lib/data/contentful.rb` |
| `units_tag` / `add_unit_data_attributes` | `helpers/markup_helper.rb` | `helpers/markup_helpers.rb` |
| `fix_degrees` | `helpers/text_helper.rb` | `helpers/text_helpers.rb` |
| Cover image URL and its `<img>` | `helpers/images_helper.rb` | `helpers/image_helpers.rb` |
| The blurhash placeholder | `services/blurhash_placeholder.rb` | `helpers/image_helpers.rb` |
| The card `sizes` and its widths | `config/srcsets.yml` | `data/srcsets.yml` |

⚠️ **The cover image of a card is in two places, and no check compares them.** The api renders the
card of the trending widget, and the build renders each other card, and the two go on the same page.
The shape (3:2), the `sizes` list, the widths, and the attributes must be the same. The
`widget_markup_contract_spec` compares the outer element of the **collection** only.

⚠️ **`api/config/srcsets.yml` is a copy of `web/data/srcsets.yml`, word for word**, and it is the
one duplication in this table that a check covers: `api/spec/contracts/srcsets_contract_spec.rb`
compares the two files. The api uses the `card` variant alone, and the other variants stay only to
make the copy one command: `cp web/data/srcsets.yml api/config/srcsets.yml`. The api cannot read
the file of web, because its Docker image holds `api/` only. ⚠️ That spec reads a `web/` file, thus
`web/data/srcsets.yml` is in the `paths:` of `api.yml`, for the same reason as the placeholder
paths.

⚠️ The two blurhash copies use different Redis keys, on purpose: the build writes
`blurhash:jpeg:*` in the Redis of web, and the api writes `blurhash:svg:*` in `kona-redis`. The two
keyspaces are separate, thus neither app can read the value of the other one.

⚠️ `Api::MarkupHelper#render_summary_body` is a smaller `render_body`, on purpose, but two of its
steps are necessary: it **must** continue to call `fix_degrees` and `mark_affiliate_links`. Without
the second one, an affiliate link loses its `rel="sponsored nofollow noopener"` disclosure, and that
link has the disclosure at each other place on the same page. The removal gives no message.

⚠️ `open_external_links_in_new_tabs` is truly **different** in the two apps: web omits a link to the
same host, and the api opens each absolute link. The api assumes that a card body links only to
another site. No test checks that assumption.

The site **wordmark** and the **favicon** are also in two places.
`web/source/partials/_logo.svg.erb` is a copy in `api/app/views/layouts/_logo.html.erb`, for the
admin header, and `web/source/favicon.ico` is a copy in `api/public/favicon.ico`. Both are safe: the
two copies never appear on the same page, and a difference gives only an old admin logo or an old
tab icon. Copy the files again when the mark changes.

## Code style

- ⚠️ **Write each comment, all the inline documentation, and each change to a `CLAUDE.md` file in
  ASD-STE100 Simplified Technical English, and keep it short.** This applies to new text and to a
  change to text that exists. Use the active voice, a simple tense, one topic in each sentence, and
  a maximum of 25 words in a sentence. Use the approved words: *get*, not "fetch"; *make*, not
  "build"; *need*, not "require"; *check*, not "verify"; *because*, not "since"; *for example*, not
  "e.g.". The technical names and the technical verbs of this domain are permitted: cache, render,
  parse, proxy, enqueue, and more. Do not use an `-ing` clause, an idiom, or a long aside between
  dashes.
- **Keep each comment short.** Say what a method or a function does, and give its parameters and its
  return value, with RDoc or YARD in Ruby, and with JSDoc in JS and TS. Do not say what the code
  already says.
- **Do not write history.** Write no changelog, no story of a migration, no "this used to be…", no
  record of a measurement, and no note about a method that a person tried and then removed. Those
  belong in git.
- **Give a reason only when that reason is necessary**: a rule that the code does not show, and that
  a probable "improvement" would break. Use one sentence or two, with a ⚠️. Put a longer text in a
  `CLAUDE.md`.
- The same applies to each `CLAUDE.md` file: it holds what an agent cannot find in the code, that
  is, a contract between the two apps, a configuration in a dashboard, and a rule that the code does
  not show. Keep each one short.
- Never write a production host name in the code. Refer to the text below.

## Production domains — never hardcode

⚠️ **Never write a production host name at any place**: not in the code, not in a comment, not in a
document, not in an example, not in a test, and not in the CI configuration. This applies to the
public site host, the public API host, the admin host, and the fly.io origin host. Each one comes
from the configuration:

- The API origin: `KONA_API_URL`. The web build, the `/widgets/*` proxy, and the Slack link of the
  CI of the api use it.
- The public API host: `API_HOST`, in the api. The route constraint uses it to keep each route for
  the owner off that host. Give the host name only, with no scheme.
- The site URL: `URL` in web, and `SITE_URL` in the api.
- The Whoop redirect: `WHOOP_REDIRECT_URI`. ⚠️ It must name the **admin** host, because the callback
  route does not exist on the public API host.

Where you need an example host name, use `https://<your-app-host>/…`.

The **root `README.md` is the one exception**: its first line links to the site by its name, which is
the purpose of a README, and no code reads that file. This rule is about a host name that a build, a
request, a test, or a workflow *uses*.

## Cloudflare sits in front of everything

⚠️ **No file in this repo configures the zone.** Each setting is in the dashboard, `grep` cannot
find it, and more than one code path needs it. Each production request goes through Cloudflare
before it reaches the Worker or fly. Thus read the zone before you decide that a problem is in the
code.

⚠️ Each rule below names a host name that **a person typed and that nothing checked**. A host name
with an error saves correctly, shows as Active, and matches nothing, and it gives no message. That
already occurred one time. Copy each host name from the DNS records of the zone, then check that the
Events counter of the rule is more than zero.

- **The client IP** — `CF-Connecting-IP` is the only true visitor IP. The `Fly-Client-IP` of fly is
  a Cloudflare PoP. `api/config/initializers/rack_attack.rb` and `web/src/log.ts` read it. Anything
  that reaches an origin directly can write a false value in it. Thus it can be the key of a
  throttle and of a log line, but it must **never** control a ban.
- **The images** — Cloudflare Images serves each transformation from `<IMAGES_URL>/cdn-cgi/image/…`,
  and it gets the source from the R2 mirror. This needs **Transformations** on, with the mirror host
  in the list of the permitted sources.
  ⚠️ **Never add `*.ctfassets.net` to that list.** Its absence is necessary: it makes a bad or
  absent `IMAGE_HOST` fail with a message. With ctfassets in the list, the site looks correct and it
  comes directly from Contentful, and it uses the metered bandwidth that the mirror protects.
- **The OG cards** — a page with no cover image gets an `og:image` that the `kona-web` Worker renders
  when it is necessary, at `<page path>og.png` (refer to `web/src/og.ts`). This needs the **Workers
  Paid** plan: a render takes approximately 100 ms of CPU, and the Free plan permits 10 ms. Refer to
  [`web/CLAUDE.md`](web/CLAUDE.md).
- **A managed transform** — "Add visitor location headers" must be on. Without it, `CF-IPCity` and
  `CF-Region` are absent and the log has the country only.
- **`/cdn-cgi/*` never reaches an origin.** Cloudflare answers it at its own edge.

### Cache Response Rules (tagging)

A deploy does **not** invalidate the edge by itself. Thus the invalidation is a separate step: a
rule gives each response the tag `Cache-Tag: site`, and `.github/workflows/web.yml` purges that tag
at each deploy.

```
(http.host eq "<site host>" and not starts_with(http.request.uri.path, "/cdn-cgi/"))
or
(http.host eq "<api host>" and (
  starts_with(http.request.uri.path, "/widgets/articles/")
  or starts_with(http.request.uri.path, "/widgets/events/")
))
```

The first part covers the full static build. The second part covers the widget fragments that
render **Contentful** content, and it matches them by their namespace. Articles and events are
Contentful content types, thus each path below those prefixes comes from Contentful, and this rule
covers a new widget there without a change. A Contentful publish starts a deploy, which does the
purge. Thus those widgets cannot serve content from before an edit for their full edge TTL.

⚠️ **Never change this into a match on the path only or on the host only, and never widen the second
part to `/widgets/`.** A purge removes the `stale-while-revalidate` and `stale-if-error` copies of a
fragment with the fresh copy, and those copies keep the widgets on the page through a fly failure.
With the tag on each widget, a Contentful publish during a failure would remove each widget on the
full site. The live-data widgets — `weather/current`, `activity-stats`, `whoop`, and
`plausible/pageviews/:id` — render nothing from Contentful and are in their own namespaces, and that
is what keeps them out of this rule.

⚠️ **The OG card paths are NOT outside the first part, on purpose.** The content addresses each
article card, thus such a card needs no purge. But a **listing page** — the blog index, a tag
archive, and the home page — is not a Contentful entry. Thus its card URL never changes, and its
`og:title` can change. For those pages, the deploy purge is the only automatic refresh, and it is
always correct, because a Contentful publish is the thing that changes such a title.

⚠️ **The host of the image mirror is absent from both parts, on purpose.** Each of its objects is
immutable and the content gives its address, thus a purge can correct nothing. And with the tag,
each content publish would remove the full image cache.

A **second** rule gives each widget on the api host the tag `widgets`. It exists only to make a
manual `POST /zones/<id>/purge_cache` with `{"tags":["widgets"]}` one call and not approximately 60.

The two rules **stack**: a widget below `/widgets/articles/` or `/widgets/events/` gets both tags.
Each rule uses the **Add to existing tags** action, and that action makes them add. The order of the
two rules does not change the tags.

⚠️ **Keep the action of each rule at "Add to existing tags".** With "Override existing tags", the
`widgets` rule would remove `site` from each Contentful widget. The deploy purge would then miss
those widgets, and it would give no message.

⚠️ **Never put `widgets` in the deploy purge.** That workflow purges `{"tags":["site"]}`, and it must
purge that tag only, for the reason above. Use the manual purge when the cached copy of a widget is
incorrect and time cannot correct it: after a change to a `cache_widget` TTL, because a cached
fragment keeps the `CDN-Cache-Control` that it had when it went into the cache, and after a markup
change that must arrive with the change to the web placeholder.

⚠️ A **Contentful widget below a NEW top-level namespace needs a change to this rule in the
dashboard**, and no file in the repo gives you that message. Without that change, the widget serves
old content for all time, and it gives no message.

⚠️ **Cloudflare Trace cannot show these rules.** Trace walks the request phases only, and it never
gets a response from an origin. To check a tag, purge it, then read `CF-Cache-Status` on the next
request.

(A `Cache-Tag` response header from an origin also works, and purge by tag is on each plan. Thus
these rules are a decision and not a necessity. Two reasons keep them. First, the site host has no
origin that writes a header: each page is a static file from the asset layer of the Worker. Thus
that half needs a rule in each condition. Second, a header for the widget half would then give one
tag two sources, in two apps and two deploy pipelines. One rule covers the two hosts instead. The
cost is discoverability, and the warning above about a new namespace is that cost. These rules run
in the `http_response_cache_settings` phase, after the response of the origin. That phase includes
each subrequest of a Worker, and that puts the widget fragments in reach.)

### Cache Rules (edge TTL)

There is one rule, and its scope is much smaller than it appears to need:

```
http.host eq "<site host>"
and not http.request.uri.path contains "."
and not starts_with(http.request.uri.path, "/cdn-cgi/")
and not starts_with(http.request.uri.path, "/widgets/")
and not starts_with(http.request.uri.path, "/api/")
and not starts_with(http.request.uri.path, "/pa/")
```

The response can go in the cache. **Edge TTL: ignore cache-control, 1 year.** **Browser TTL: respect
origin.**

The purpose is to **keep the archive in the cache**. Most URLs here are old posts, and each PoP gets
few requests for them. Thus a short edge TTL removes them between two visits. The TTL is a maximum
and not a promise: each PoP removes an entry under LRU in each condition, thus this TTL only stops
being the limit. The reason for each exclusion:

- **`contains "."`** selects the HTML, because a page URL has no extension. Thus each asset with a
  fingerprint keeps the `immutable` policy that it already declares correctly. It is also what keeps
  the **OG cards** out of this rule with no clause of their own, and that is why that route has an
  extension.
- **`/widgets/`, `/api/`, and `/pa/`** — three of the four `run_worker_first` route families are on
  the site host and have no extension. A TTL of one year would keep each widget in the cache for all
  time, and a cached `/pa/*` would give incorrect analytics. **A new `run_worker_first` entry needs
  a matching exclusion here**, and no file in the repo gives you that message.

⚠️ **Never add a cache rule on the api host.** The `CDN-Cache-Control` of the origin gives the TTL of
each widget, and a cache rule would replace each of those values.

⚠️ **The deploy purge is the only thing between a TTL of one year and a page in the cache for one
year.** The rule ignores `Cache-Control`, thus a purge that matches nothing, with no message, leaves
that copy at the edge for almost all time. Count a purge failure in `web.yml` as an outage of the
page.

### Zone security rules

The zone is on Cloudflare **Pro**, thus the WAF **Managed Rules** and **Super Bot Fight Mode** apply
to the full zone, and this **includes the api host**. Almost all the traffic there is between two
machines, and it looks exactly like the traffic that those two features stop.

⚠️ **The skip rule must exist *before* you set those features on.** Without it, each widget gives a
403 on the full site at the moment that SBFM starts.

The custom rules, in order from the top. Each BLOCK rule stays above the skip rule, and the skip
rule does not have "All remaining custom rules" on:

| # | Rule | Expression | Action |
|---|---|---|---|
| 1 | A bad Linux crawler with a false Google referrer | A desktop Linux Chrome UA and a `google.com` referer | Block |
| 2 | Block the scanner noise | The path families that no host in the zone serves. Refer to the text below. | Block |
| 3 | Block a request for an original image | `http.host eq "<image host>" and not any(http.request.headers["via"][*] contains "image-resizing")` | Block |
| 4 | Skip the bot protection off the admin host | `http.host ne "<admin host>"` | Skip → each managed rule **and** each SBFM rule |

**Rule 1** matches too much, and we know that: those conditions also match a true person on a desktop
Linux machine who clicks a Google result, and a block of that person is an accepted cost. The bot
goes past a managed challenge, a challenge with no interaction, **and** an interactive challenge.
Thus the UA and the referer are the only things left that stop it. Do not change it into a
challenge: that method already failed.

**Rule 2** is one long `or` over `lower(http.request.uri.path)`, and it matches by *family*: the
extensions that a scanner uses (`.php`, `.env`, `.sql`, `.yml`, `.pem`, `.key`, and more); the
prefixes of a tool or a framework (`/wp-`, `/cgi-bin/`, `/actuator/`, `/phpmyadmin/`, `/k8s/`,
`/terraform/`, `/secrets/`, `/config/`, `/deploy/`, `/flask/`, `/pki/`, `/home/`, `/analytics/`);
the file names of secret material (`credential`, `cognito`, `/id_`); a **dot segment at each
position** (`contains "/."`, but not `/.well-known/`); and each method that is not `GET`, `HEAD`, or
`POST`.

⚠️ A scanner writes each **dot as a percent escape** (`/terraform/%2eenv%2estaging`), to go past a
match on the extension. Thus the rule also blocks a plain `contains "%2e"`. The **Normalize incoming
URLs** setting of the zone decides which of the two forms the rule sees, and Security Events shows
the raw path in both conditions. Thus you cannot know which form the rule saw. Each clause matches in
*both* forms, and you must remove neither one.

⚠️ Each prefix uses `starts_with`, and the rule applies to the full zone. `activate
:directory_indexes` puts each page at `/<slug>/`. Thus this rule would block a top-level page with
the slug `config`, `home`, `analytics`, or `deploy`, through its own prefix clause. Read
`data/pages.json` before you add a prefix, and read this note again if a new page ever gives a 403.
Each clause must also be false for the api host (`/widgets/`, `/api/`, `/webhooks/`, `/whoop/`,
`/auth/`, `/signin`, `/signout`, `/sidekiq`, and `/up`) and for the shape of an R2 key
(`{space}/{asset id}/{token}/{filename}`).

⚠️ **The admin UI is at the root of the admin host**, thus its pages use top-level paths: today
`/spam`, `/location`, `/connected-apps`, and `/course-maps`. They have the same problem from the
other side: a new admin page with the name of one of those prefix families would give a 403 in the
full zone. Read this rule before you give a name to a new page.

**Rule 3** knows "Cloudflare Images gets a source" from "a person types the URL", through the
`image-resizing` text that Cloudflare puts in `Via`.

⚠️ **Never change it into a block of the full host.** The fetch of the transformation also goes
through the rules, thus a block of the host gives a 403 for **each image on the site**. After an
edit, check **both** directions: a direct `curl` must give a 403, *and* a page must still show its
images.

⚠️ **It is a difficulty and not a boundary**, and a measurement gave the size of the two gaps. `Via`
is an ordinary request header (`curl -H 'Via: 1.1 image-resizing'` gives a 200), and the
transformation endpoint on the site host takes each width. Thus
`/cdn-cgi/image/width=7728/<source>` gives a render at the full resolution. Only a **smaller stored
original** would limit the resolution that a person can get: the mirror would hold `?w=2560` and not
the original file.

**Rule 4** is one condition and not a list of the permitted paths of each host, because **the api app
does that itself**: `API_HOST` in `api/config/routes.rb` draws each route for the owner off the admin
host only. Those routes are `/signin`, `/signout`, `/auth/*`, `/whoop/auth`, `/whoop/callback`,
`/sidekiq`, and the admin UI at `/`. Thus the public api host answers only `/up` and the three
machine namespaces.

⚠️ **That route constraint is the reason that this rule is safe.** A route for the owner outside that
constraint goes on a host with no managed rules and no SBFM, and nothing in the zone would find it.
`api/spec/requests/host_constraints_spec.rb` tests both directions.

⚠️ **This rule is a denylist, thus each new host name in the zone has no protection by default**: a
staging subdomain, a second origin, and a new service. The list of permitted hosts, which this rule
had before, failed in the opposite direction and gave a much clearer message. Add each new host here,
with care.

The reason for the skip rule, for each host:

- **The site host** — SBFM blocked **each feed reader and each Open Graph scraper**. "Verified bots:
  Allow" covers Googlebot and Bingbot, but not the unfurler of Slack, Mastodon, or Discord, and not
  an RSS client. Those are exactly the traffic that a blog needs. Those unfurlers are also the only
  readers of the OG cards. ⚠️ This host is not static only: `run_worker_first` takes `/widgets/*`,
  `/api/contact`, `/pa/*`, and the card paths, and `POST /api/contact` takes true text from a user.
  The managed rules never protected that endpoint: the honeypot, Turnstile, Akismet, the length
  limits, and the `contact/ip` throttle protect it. Do not use this skip rule as a reason to remove
  one of those.
- **The image host** — the source fetch has no browser fingerprint, which is the clearest "this is a
  machine" result. Thus SBFM would remove each image at the same time.
- **The public api host** — `web/src/api-proxy.ts` sends an `authorization` header only, on purpose,
  because the cache entry must have the same bytes for each viewer. That gives the same "this is a
  machine" fingerprint. `/api/` also covers the callers at build time. `/webhooks/` takes POSTs with
  Contentful rich text, with no person present, and that text will start a managed injection rule at
  some time. An HMAC checks both, thus a managed rule adds nothing. ⚠️ A block there gives **no
  message**: nothing shows an error, and the PDS sync simply stops.
- **The admin host** — the one host with the protection on, and the only one whose traffic is a true
  browser that one person controls: the Google sign-in, the admin UI at the root of the host, the
  Sidekiq UI, and the Whoop OAuth round trip. A managed challenge there is acceptable, and it is not
  acceptable at any other host. The `/assets/*` files of the admin UI, which have a fingerprint, are
  also on this host, and the **static resource protection of SBFM is off**, which is what keeps them
  free of a challenge. ⚠️ Point each external uptime check at `/up` on the **public** host. The
  checks of fly reach the app on its internal host and never go through the zone.

⚠️ **The rate limiting rules are NOT in the skip list, on purpose.** Do not add them.

**The managed rules** — start the Cloudflare Managed Ruleset with the action set to **Log**, read
Security Events for a week, then use the default actions. The **OWASP Core Ruleset** is **not** on,
on purpose: it gives many false results, and the main thing that it would catch here is the text of
the contact form. If you ever set it on, use PL1, the High threshold (60), and the Log action, and
never a stricter value.

**Super Bot Fight Mode** — definitely automated: Block. Likely automated: Managed Challenge. Verified
bots: Allow. JS detections: on. **Static resource protection: off**, because it would give a
challenge to the CSS, JavaScript, and font requests of the site. ⚠️ It does not replace custom rule
1: that scraper goes past an interactive challenge.

**The rate limiting rules.** The Pro plan permits two:

- `/api/contact` — it stays on **Block**. ⚠️ Never use a challenge action: the native POST path with
  no JavaScript cannot answer a challenge, and that would break the path for a browser with no
  JavaScript.
- A limit on a crawler on the site host — a GET or a HEAD outside `/cdn-cgi/`, for each IP,
  approximately 200 requests each minute, then a Managed Challenge. ⚠️ Do not use a much lower
  number: Pagefind gets a group of index files for each search, and Turbo gets a page early when the
  pointer goes to a link. Thus one true reader is much above a simple rate.

**The other zone settings.** They are deliberate but not necessary: Smart Tiered Cache on, Page
Shield script monitoring on, and Early Hints, HTTP/3, 0-RTT, and Crawler Hints on. **Polish and
Mirage stay off**, because each image already goes through `/cdn-cgi/image/*`, which selects the
format and the quality.

**A zone rule blocks the bots, and no code does.** A person deleted the `block-bots` edge function
(`3c4e0044`). Do not add it again. If the referral traffic looks incorrect, read rule 1 before you
read the code.

## How the two apps connect

The routes of the API are in three namespaces. `/widgets/*` gives HTML fragments, through the
proxy. `/api/*` takes or gives structured data, and a caller reaches it directly at `KONA_API_URL`,
but `POST /api/contact` is different. `/webhooks/*` takes the inbound webhooks. The web build reads
three paths at build time: `GET /api/standard-site`, `GET /api/related`, and `POST /api/icons`.

1. A browser asks for `/widgets/*`, or does a `POST /api/contact`, on the main site.
2. `run_worker_first` in `web/wrangler.jsonc` takes those paths, thus they go to the Worker code and
   not to the static asset layer.
3. `web/src/api-proxy.ts` sends the request to `KONA_API_URL`.
4. The code makes the upstream fetch cacheable with `cf: { cacheEverything: true }`, because a widget
   URL has no extension and the Cloudflare default, which uses the extension, would cache nothing.
   The `CDN-Cache-Control` of the origin gives the full TTL (RFC 9213). One copy in the cache serves
   each viewer. ⚠️ The cache holds that entry under the **api** host name, and that is why the
   `site` tag rule applies to that host.

⚠️ The proxy takes `/api/contact` **only, and not `/api/*`**. Do not widen it. With `/api/*`, a
browser could reach `POST /api/location`, `POST /api/icons`, and `POST /api/build`, which starts a
production deploy, and the proxy would add the bearer token.

The rules of the proxy. Do not break one of these:

- It sends `accept` only, and on the contact path only, and it **adds** a constant
  `Authorization: Bearer <API_TOKEN>`. It removes the `authorization` header of the client. The
  token is the same for each viewer, thus each upstream request is the same and there is one shared
  cache entry. ⚠️ `API_TOKEN` must be in the secrets of the Worker in the dashboard, and it must
  **be the same as the token of the API**. If it is not, each widget gets a 401 on the full site.
- It sends the `Cache-Control` of the origin, the `ETag` and `Last-Modified` validators, and the
  **`Age`** of the copy in the edge cache. ⚠️ **`Age` is necessary.** The browser policy is
  `max-age=0, stale-while-revalidate=N`, and RFC 9111 makes the browser measure that window from
  the age of the response. Without Age, each viewer gets a full window in addition to the time that
  the edge already held the copy. On a counter that only goes up, that looks like a number that goes
  *down*.
- It does **not** send `CDN-Cache-Control` to the browser.
- The **path alone** is the key of the edge cache: no query parameter, and no value for each user.
  Put each input of a widget in the **path**.
- It gives an empty `502` with a short cache time when the upstream call raises. Thus a short
  problem at the origin removes the widget and does not keep an error in the cache.
- **On the contact path only:** it sends the true visitor IP, UA, and geo data in the
  `X-Kona-Client-*` headers, because the origin cannot see them: the zone changes each `CF-*` header
  to describe the egress of the Worker. It also sends the `Location` header for the redirect of a
  browser with no JavaScript. The API uses those values for Akismet, for the rate limit, and for the
  notification email, and **never** for a ban.

### Contact form (`POST /api/contact`)

The form is a **web partial** (`source/partials/_contact_form.html.erb`), and it is **not** raw HTML
in the Contentful body. SmartyPants would make the quotation marks in its attributes curly, and that
would break the field names and the Stimulus attributes. The intro text stays in Contentful.

`Api::ContactController` removes each submission with a value in the honeypot, which is the hidden
`comment` field, and it adds a `ContactMailJob` to the queue. That job does the spam check with
**Akismet** and sends the email with **Resend**, which is an HTTPS API, because fly blocks outbound
SMTP. It sets `Reply-To` to the sender. The form also works with no JavaScript: with JavaScript, the
`contact` Stimulus controller posts with `fetch` and `Accept: application/json`, and it gets a 204 or
a 422, shows a toast, and does not navigate. With no JavaScript, the native POST sends
`Accept: text/html` and gets a 303 to `/contact/success`. Both use the same endpoint and the same
checks.

The layers of protection: the honeypot and Akismet on both paths, the length limits on the server, a
rack-attack throttle for each visitor on the `X-Kona-Client-IP` from the proxy, and **Cloudflare
Turnstile**. ⚠️ Turnstile needs JavaScript, thus the app checks it **on the JSON path only**.
Turnstile and Akismet both permit the message when there is *no configuration*. When Akismet *has* a
configuration, it fails **closed**: a failure of the service makes the intake job run again, and the
app does not deliver a message with no check.

A message that Akismet marks goes to the **quarantine, and the app does not remove it**: Redis holds
it for a month and the Spam page of the admin lists it. On that page, the owner sends the email and
the app tells Akismet that the mark was incorrect. Refer to [`api/CLAUDE.md`](api/CLAUDE.md).

## The image mirror

Each image is a Cloudflare Images transformation, and Cloudflare gets the **source**, with no
transformation, from the host that the URL names. A source outside the zone cannot use Tiered Cache
and cannot use Cache Reserve. Thus each PoP got the full-size original from Contentful by itself, and
it got that file again after an eviction. For that reason the app copies each asset into an **R2
bucket**, which its own custom domain in the zone serves, and that host name is the source of each
transformation.

The two apps meet **only in the shape of a URL**: there is no request between them, there is no
import, and neither one checks the other:

| | Who | What |
|---|---|---|
| Writes | `api` — `AssetMirror` and `AssetSyncJob`, from the asset-publish webhook, and `rake assets:backfill` | An R2 object whose key is the Contentful path, **with no change**: `{space}/{asset id}/{token}/{filename}` |
| Reads | `web` — `Contentful#rewrite_image_urls` at build time, and only when `IMAGE_HOST` has a value | It changes **the host only**, thus the path that it writes is that same key |
| Reads | `api` — `ImagesHelper#cdn_image_url`, at the render of the trending card | The same change, at request time, from `IMAGE_HOST` |

⚠️ **The two sides match each `*.ctfassets.net` host, and they must continue to match the same
set.** Contentful serves many ordinary image assets from `downloads.ctfassets.net`, and that host
has no Images API. If you change one side to `images.ctfassets.net` only, those assets go to
Contentful for all time, and they give no message.

⚠️ **A difference between the two sides makes each image on the site 404, and nothing reports it.**
Such a difference is the wrong bucket, the wrong custom domain, a key shape that a person "improved",
or an `IMAGE_HOST` with a value before the backfill was complete. The order of the steps: the
bucket, the custom domain, the SBFM skip rule, and the mirror host in the Transformations list; then
a deploy of the api with the `R2_*` secrets; then `rake assets:backfill` to its end; and *only then*
a value for `IMAGE_HOST` in the build environment of web. The images are broken between the last two
steps, thus keep that time short. And never correct it with ctfassets in the list.

Three results:

- **The mirror copies a publish only. It ignores an unpublish and a delete, on purpose.** `web` reads
  Contentful with a **preview** token, thus a page from the build still points at an unpublished
  asset. Each object is immutable, thus nothing needs an invalidation.
- **A blurhash also goes through the mirror**: `encode_blurhash` resizes with `cdn_image_url`, as
  each other image does. ⚠️ It must ask for an `fm:` value. With no format, Cloudflare returns the
  source format, and a libvips with no loader for that format fails the decode into a `rescue`. There
  is then no placeholder, and no message.
- **Each environment needs `IMAGE_HOST`, and this includes your own machine. It is not a way to go
  back.** The rewrite does nothing when the value is blank, but the Transformations list has the
  mirror host only. Thus an `IMAGE_HOST` with no value leaves each image at ctfassets, and each one
  gets a **403**. To go back to Contentful, change that list in the dashboard first.
- **Custom rule 3 blocks a direct request for a mirrored original.** That rule is a difficulty and
  not a boundary. Refer to the text above. The mirror holds the true originals today: 1.39GB, and
  that includes twelve camera JPEG files of 20MB to 38MB. Thus a person who wants those files can
  still get them.

## The cross-app HTML contract (most important)

The API gives HTML fragments that **replace** a placeholder element in the static site. Thus the
markup of the two must have the same structure in the two apps.

`web/source/javascripts/stimulus/controllers/live_update_controller.js` reads
`data-live-update-url-value`, gets the fragment, and, for a response that is **not empty**, replaces
the full placeholder element. It gets the fragment on connect when the element is a **placeholder**
(`data-live-update-placeholder-value="true"`), and when the content of that URL is more than one
minute old. It gets the fragment again at a tab `visibilitychange`, with the same minimum age. That
clock is at the module level, and its **key is the URL**. Thus it stays after the swap of the
placeholder for the fragment, and it stays through a Turbo back or forward **restoration visit**,
which renders a cached snapshot that contains the *fragment* and which never gets new content.
Without that clock, a widget from a restoration visit would show the content from the last time that
the user left the page. On a view counter, that is a number that goes down.

The results:

- The **outermost element of the API fragment must have** `data-controller="live-update"` and
  `data-live-update-url-value`. Without them, it gets no new content after the first swap. ⚠️ It
  must **NOT** have `data-live-update-placeholder-value`: that flag means "I am an empty skeleton",
  and on a fragment it makes a short fetch failure **delete content that the page already shows**.
- Its tag, its CSS class names, and its DOM shape must be the same as in the placeholder.
- An **empty** response makes the controller **remove the element**. Thus the widget goes away and
  no skeleton stays on the page. An empty body is the "no data" answer, on purpose. Do not change it
  into markup. This applies in each condition. A non-2xx status and a network error are different:
  they remove **a placeholder only**.

A placeholder makes the shared attributes with `live_update_attrs`
(`web/lib/helpers/site_helpers.rb`), and an API view makes the matching outer element with
`live_update_url`.

⚠️ **Not each element on the web side is a skeleton.** `live_update_attrs(url, placeholder: false)`
marks an element that the build renders with **real content**, and the fragment then adds to that
content and does not fill an empty element. Today that is the upcoming-races section only: the build
writes it from `data/events.json`, and the api renders it again with the race-day weather and a
"Today's Race" section. Such an element must not have the placeholder flag, for the same reason as
the api fragment: a short fetch failure would delete content that is already correct. It still gets
the fragment on connect, because the controller counts a URL with no fetch as old. An **empty**
response still removes it, and that is the api saying that there is no upcoming race.

`web/test/browser/controllers/live_update.test.js` tests the **web half**.
`api/spec/contracts/widget_markup_contract_spec.rb` compares the two sides: it reads both files
across the monorepo and checks that the placeholder and the fragment have the same tag, the same
classes, and the same `data-nosnippet`. It checks the outer element only, and a person keeps each
element in it the same in the two apps.

⚠️ That spec is in the api but it reads `web/`, and `api.yml` has a path filter. Thus the `paths:` of
that workflow has each placeholder path that the spec reads, **on purpose**. Without those paths, no
check would run on the edits that break the contract most often. The spec fails when the two lists
become different.

| Widget | web placeholder | api view | endpoint |
|---|---|---|---|
| Activity stats | `source/partials/placeholders/_stats.html.erb` | `views/widgets/activity_stats/show.html.erb` | `/widgets/activity-stats` |
| Whoop | `source/partials/placeholders/_whoop.html.erb` | `views/widgets/whoop/show.html.erb` | `/widgets/whoop` |
| Current weather | `source/partials/placeholders/_weather.html.erb` | `views/widgets/weather/current.html.erb` | `/widgets/weather/current` |
| Pageviews | `source/partials/article/_full.html.erb` (inline `span`) | `views/widgets/plausible/pageviews.html.erb` | `/widgets/plausible/pageviews/:id` |
| Upcoming races † | `source/partials/_upcoming_races.html.erb` | `views/widgets/events/upcoming.html.erb` | `/widgets/events/upcoming` |
| Trending articles | `source/partials/placeholders/_trending.html.erb` | `views/widgets/articles/trending.html.erb` | `/widgets/articles/trending[/:id]` |

† This is not a placeholder: the build renders it with real content and the fragment adds to that
content. Refer to the `placeholder: false` note above.

The shared CSS is in `web/source/stylesheets/components/`. The fragments of the api use the classes
of `_collection.scss`, `_entry.scss`, `_event.scss`, `_stats.scss`, and `_weather.scss`:
approximately 38 classes, and also `sr-only`. The two apps own those five files together. A list of
the classes here would become incorrect at the first change to a widget.

The two sides make the group of live-update attributes with a helper: `live_update_attrs` in
`web/lib/helpers/site_helpers.rb`, and the helper in `api/app/helpers/live_update_helper.rb`. Neither
side writes those attributes in each view. The helper of the api omits
`data-live-update-placeholder-value`, on purpose, and `api/spec/support/live_update_contract.rb` is a
shared example that each widget request spec includes. That example fails when a fragment ever gets
that attribute.

⚠️ **When you change the markup, the class names, or the DOM shape of a widget, edit the web
placeholder and the api view together.** Then read the rules of the proxy above again.
