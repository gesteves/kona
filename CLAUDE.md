# Kona — monorepo guide

This file gives the **contract between the two apps** and the reasons for the Cloudflare
configuration. For the rules of one app, read the nearest `CLAUDE.md`:

- [`web/CLAUDE.md`](web/CLAUDE.md) — Middleman static site (the blog).
- [`api/CLAUDE.md`](api/CLAUDE.md) — Rails API serving dynamic widgets.
- [`utilities/contentful/CLAUDE.md`](utilities/contentful/CLAUDE.md) — Contentful migrations + taxonomy.

Work on one app from its own directory. Each app has its own `Gemfile`, its own `.env.example`, and
its own test suite.

`redis/` holds the `fly.toml` of `kona-redis`. That Redis is the cache and the Sidekiq queues of the
api, and it is also the only copy of some records. Refer to [`api/CLAUDE.md`](api/CLAUDE.md).

⚠️ **A `.env` on your own machine must never hold a production value**, and this includes each
`REDIS_URL`. Both `.env.example` files give the reason. Use the local Redis that `overmind start`
runs.

### `utilities/` — local-only tools

⚠️ **The purpose of this directory is that nothing here goes to production.** `web.yml` and
`api.yml` have a path filter on `web/**` and on `api/**`. Thus a change below `utilities/` builds
nothing, deploys nothing, and never starts the `Cache-Tag: site` edge purge of the Web deploy. **Do
not make `web/` or `api/` depend on a file here**, at build time or at request time.

- ⚠️ **`utilities/aqi-map/` must not go to production**: it binds `127.0.0.1` and it proxies a
  PurpleAir key with no authentication of its own.
- ⚠️ `utilities/aqi-map/lib/epa_aqi.rb` is a **copy** of the EPA math in
  `api/app/services/weather/purple_air.rb`, and `utilities/race-weather/` loads that copy. A correction in
  one file does not reach the other. `spec/epa_aqi_check.rb` tests the copy against the published
  equation.

## Local development

`overmind start` runs the full stack against the local api. `cd web && bundle exec middleman` runs
the site alone, against the deployed api. `Procfile.dev` and `.overmind.env` give the details.

The api writes its log to `api/log/development.log`, and **not** to its overmind pane.

A group of `ActionController::RoutingError` messages at the **first** page load of the api is not a
problem. They go away at the next load. `routes.rb` ends with a `*unmatched` catch-all, thus nothing
can raise that error after Rails loads the routes. Those messages mean that the route set was empty
for a short time. Rails in development has `enable_reloading = true` and `eager_load = false`, thus
the first request draws the routes again while the two other Puma threads already answer the five
widget requests of the page. It is a race in the reload of the development mode, and it is not the
proxy.

## Duplicated across the two apps

The logic in this table is in both `api/` and `web/`, because it renders markup that goes onto the
**same page**. The static build renders an article and the upcoming races, and the api renders the
same summary text again into the trending fragment, and the same races into the upcoming-races
fragment. A difference between the two changes the typography, or the behavior of a link, in the
middle of a page. Most of these files do not name their copy, thus read this table before you
change one:

| Logic | api | web |
|---|---|---|
| `markdown_to_html` + `smartypants` + `heading_text` | `helpers/markdown_helper.rb` | `lib/helpers/markdown_helpers.rb` |
| `clock_icon_svg` | `helpers/icons_helper.rb` | `lib/helpers/icon_helpers.rb` |
| `article_permalink_timestamp` | `helpers/articles_helper.rb` | `lib/helpers/article_helpers.rb` |
| Canonical article path | `services/articles/article_attributes.rb` | `lib/data/contentful.rb` |
| `units_tag` / `add_unit_data_attributes` | `helpers/markup_helper.rb` | `lib/helpers/markup_helpers.rb` |
| `fix_degrees` | `helpers/text_helper.rb` | `lib/helpers/text_helpers.rb` |
| Cover image URL and its `<img>` | `helpers/images_helper.rb` | `lib/helpers/image_helpers.rb` |
| The blurhash placeholder | `services/contentful/blurhash_placeholder.rb` | `lib/helpers/blurhash_helpers.rb` |
| The card `sizes` and its widths | `config/srcsets.yml` | `data/srcsets.yml` |
| `article_click_classes` + `ARTICLE_CLICK_EVENT` | `helpers/plausible_helper.rb` | `lib/helpers/site_helpers.rb` |
| `upcoming_races`, `event_collection_variant`, `event_timestamp_tag`, `parse_event_date` | `helpers/events_helper.rb` | `lib/helpers/event_helpers.rb` |
| `live_update_attrs` | `helpers/live_update_helper.rb` | `lib/helpers/site_helpers.rb` |

⚠️ **The cover image of a card is in two places, and no check compares its `<img>` attributes.**
The api renders the card of the trending widget, and the build renders each other card, and the two
go on the same page. The `sizes` list, the widths, and the attributes must be the same.
`srcsets_contract_spec` compares the `sizes` and the widths, and `widget_markup_contract_spec`
compares the outer element of the **collection** only.

The site **wordmark** and the **favicon** are also in two places.
`web/source/partials/_logo_symbol.svg.erb` holds the paths of the mark, which each `<use>` in
`_logo.svg.erb` draws, and `api/app/views/layouts/_logo.html.erb` is an inline copy of those paths,
for the admin header, and `web/source/favicon.ico` is a copy in `api/public/favicon.ico`. Both are safe: the
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
  a probable "improvement" would break. Use one sentence or two, with a ⚠️.
- ⚠️ **Each warning has one home: a comment at the code that it guards.** Never copy a code comment
  into a `CLAUDE.md`.
- The same applies to each `CLAUDE.md` file. It holds what an agent cannot find in the code and
  cannot read with `cf`: a contract between the two apps, the reason for a dashboard configuration,
  and a rule that the code does not show. It does not copy a configuration. Keep each one short.
- **An edit to a `CLAUDE.md` is not a routine step of a change.** Add a line only for a rule that has
  no place in the code.
- Never write a production host name in the code. Refer to the text below.
- ⚠️ **In `api/`, each user-facing word of the admin UI goes in `config/locales/en.yml`**, and
  never in an ERB file, a Ruby method, or a JS file. The rule, and what stays out of it, is in
  [`api/CLAUDE.md`](api/CLAUDE.md). This applies to the admin of `api/` only: `web/` is Middleman
  and has no Rails i18n.

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

⚠️ **No file in this repo configures the zone, and this file does not copy it.** Read the live
configuration with the `cf` CLI: `cf rulesets list --zone <zone>`, then
`cf rulesets entrypoint get <phase> --zone <zone>` for the rules of one phase. `cf bot-management
get`, `cf dns records list`, `cf managed-transforms list`, and `cf zones settings get <setting>` give
the rest. Read the zone before you decide that a problem is in the code. This section keeps only the
reason for each rule, and each link between a rule and the repo.

⚠️ Each rule names a host name that **a person typed and that nothing checked**. A host name
with an error saves correctly, shows as Active, and matches nothing, and it gives no message. That
already occurred one time. Copy each host name from the DNS records of the zone, then check that the
Events counter of the rule is more than zero.

- **The images** — Cloudflare Images serves each transformation from `<IMAGES_URL>/cdn-cgi/image/…`,
  and it gets the source from the R2 mirror. This needs **Transformations** on, with the mirror host
  in the list of the permitted sources.
  ⚠️ **Never add `*.ctfassets.net` to that list.** Its absence is necessary: it makes a bad or
  absent `IMAGE_HOST` fail with a message. With ctfassets in the list, the site looks correct and it
  comes directly from Contentful, and it uses the metered bandwidth that the mirror protects.
- **The source port** — a Request Header Transform Rule sets `X-Kona-Client-Port` on
  `POST /api/contact` of the site host, because `request.cf` has no port. The contact email and the
  Spam page show it. A report of a threat needs it: a carrier-grade NAT puts many subscribers behind
  one IPv4 address, and the IP, the port, and the time to the second select one. After an edit, send
  a test message and check its "Source port" line.

### The origin certificate

⚠️ **Cloudflare proxies each host, thus fly cannot renew its origin certificate by itself.** The A
and AAAA records of a host name Cloudflare, and not fly. Thus the usual check of fly fails, and
`fly certs show <host>` says "DNS records do not match the expected values" and keeps the status at
"Issuing…".

The certificate then expires, and the failure is silent and total. The fly edge sends **no
certificate**, Cloudflare answers **525 SSL handshake failed**, and **the fly log shows nothing**,
because no request completes the handshake. On the public API host this stops each widget and
`POST /api/icons`, thus the build of web fails with a 525 and names no cause.

**Each** host needs two more DNS records. Keep both **DNS only**, with no proxy:

```
CNAME _acme-challenge.<host>  →  <host>.<app id>.flydns.net.
TXT   _fly-ownership.<host>   →  app-<app id>
```

The CNAME lets Let's Encrypt do the DNS-01 challenge, and the TXT tells fly that we own a host that
a proxy fronts. `fly certs setup <host> -a kona-api` prints the two exact values, and
`fly certs check <host> -a kona-api` starts the check again after you add them.

⚠️ **Nothing in this repo watches that expiry, and there is no alarm.** Each host has its own
certificate and its own date. Read `fly certs list -a kona-api` first when a request to an origin
gives a 525.

### Cache Response Rules (tagging)

A deploy does **not** invalidate the edge by itself. Thus the invalidation is a separate step: a
rule gives each response the tag `Cache-Tag: site`, and `.github/workflows/web.yml` purges that tag
at each deploy.

The rule tags the full static build on the site host. On the api host, it tags the widget fragments
below `/widgets/articles/` and `/widgets/events/`: articles and events are Contentful content types,
and a Contentful publish starts a deploy. ⚠️ The cache holds a proxied widget under the **api** host
name, thus the rule must name that host.

⚠️ **Never change this into a match on the path only or on the host only, and never widen the second
part to `/widgets/`.** A purge removes the `stale-while-revalidate` and `stale-if-error` copies of a
fragment with the fresh copy, and those copies keep the widgets on the page through a fly failure.
With the tag on each widget, a Contentful publish during a failure would remove each widget on the
full site. The live-data widgets — `weather/current`, `activity-stats`, `whoop`, and
`plausible/pageviews/:id` — render nothing from Contentful and are in their own namespaces, and that
is what keeps them out of this rule.

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

Purge the `widgets` tag by hand only, and never in the deploy. Use it when the cached copy of a
widget is incorrect and time cannot correct it: after a change to a `cache_widget` TTL, because a
cached fragment keeps the `CDN-Cache-Control` that it had when it went into the cache, and after a
markup change that must arrive with the change to the web placeholder.

⚠️ A **Contentful widget below a NEW top-level namespace needs a change to this rule in the
dashboard**, and no file in the repo gives you that message. Without that change, the widget serves
old content for all time, and it gives no message.

⚠️ **Cloudflare Trace cannot show these rules.** Trace walks the request phases only, and it never
gets a response from an origin. To check a tag, purge it, then read `CF-Cache-Status` on the next
request.

(A `Cache-Tag` header from an origin also works. But the site host has no origin that writes a
header, and a header for the widgets would give one tag two sources in two apps. Thus one rule
covers the two hosts, and the warning above about a new namespace is the cost.)

### Cache Rules (edge TTL)

One rule gives the HTML of the site host an edge TTL of one year, and it ignores `Cache-Control`.
The purpose is to **keep the archive in the cache**. Most URLs here are old posts, and each PoP gets
few requests for them. Thus a short edge TTL removes them between two visits. The TTL is a maximum
and not a promise: each PoP removes an entry under LRU in each condition, thus this TTL only stops
being the limit. The reason for each exclusion:

- **`contains "."`** selects the HTML, because a page URL has no extension. Thus each asset with a
  fingerprint keeps the `immutable` policy that it already declares correctly.
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
machines, and it looks exactly like the traffic that SBFM stops.

⚠️ **The SBFM skip rule must exist *before* you set SBFM on.** Without it, each widget gives a 403
on the full site at the moment that SBFM starts.

Each Block rule stays above the skip rule, and the skip rule does not have "All remaining custom
rules" on.

**The scanner rule** is one long `or` over `lower(http.request.uri.path)`, and it matches by
*family*: the extensions, the tool prefixes, and the file names of secret material that a scanner
asks for.

⚠️ A scanner writes each **dot as a percent escape** (`/terraform/%2eenv%2estaging`), to go past a
match on the extension. Thus the rule also blocks a plain `contains "%2e"`. The **Normalize incoming
URLs** setting of the zone decides which of the two forms the rule sees, and Security Events shows
the raw path in both conditions. Thus you cannot know which form the rule saw. Each clause matches in
*both* forms, and you must remove neither one.

⚠️ Each prefix uses `starts_with`, and the rule applies to the full zone. `activate
:directory_indexes` puts each page at `/<slug>/`. Thus this rule would block a top-level page with
the slug `config`, `home`, `analytics`, or `deploy`, through its own prefix clause. Read
`data/pages.json` before you add a prefix, and read this note again if a new page ever gives a 403.
Each clause must also be false for each path that the api host serves, and for the shape of an R2
key (`{space}/{asset id}/{token}/{filename}`).

⚠️ **The admin UI is at the root of the admin host**, thus its pages use top-level paths. They have
the same problem from the other side: a new admin page with the name of one of those prefix
families would give a 403 in the full zone. Read this rule before you give a name to a new page.

**The original-image rule** knows "Cloudflare Images gets a source" from "a person types the URL",
through the `image-resizing` text that Cloudflare puts in `Via`.

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

**The skip rule** skips SBFM only, on the site host, on the public api host, and on the path `/up`
of each host. The managed rules run on each host. The rule names the api host and not a list of its
paths, because **the api app does that itself**: `API_HOST` in `api/config/routes.rb` draws each
route for the owner off the admin host only. Thus the public api host answers only `/up` and the
three machine namespaces.

⚠️ **That route constraint is the reason that this rule is safe.** A route for the owner outside that
constraint goes on a host with no SBFM, and nothing in the zone would find it.
`api/spec/requests/host_constraints_spec.rb` tests both directions.

⚠️ **The rule is a list of hosts, thus SBFM applies to each new host name by default.** A new host
that machines call, for example a second origin, needs an entry here, or SBFM blocks its callers
with no message.

The reason for the skip rule, for each host:

- **The site host** — SBFM blocks **each feed reader and each Open Graph scraper**, and its
  verified-bots setting can block Googlebot and Bingbot too. Those are exactly the traffic that a
  blog needs, and the unfurlers are the only readers of the OG cards. ⚠️ This host is not static
  only: `run_worker_first` takes `/widgets/*`, `/api/contact`, `/pa/*`, and the card paths, and
  `POST /api/contact` takes true text from a user. The honeypot, Turnstile, Akismet, the length
  limits, and the `contact/ip` throttle protect that endpoint. Do not use this skip rule as a reason
  to remove one of those.
- **The public api host** — `web/src/api-proxy.ts` sends an `authorization` header only, on purpose,
  because the cache entry must have the same bytes for each viewer. That gives a "this is a machine"
  fingerprint. `/api/` also covers the callers at build time. Strava POSTs its events to
  `/webhooks/` with no signature and no browser. ⚠️ **Meta also GETs each photo of a Threads post**
  from `/api/social-photos/*` on this host. A challenge there stops each Threads post with photos,
  and the only sign is an `ERROR` container in the job report.
- **The admin host** — SBFM stays on, because its traffic is a true browser that one person
  controls. The `/assets/*` files of the admin UI are also on this host, and the **static resource
  protection of SBFM is off**, which is what keeps them free of a challenge. ⚠️ Point each external
  uptime check at `/up`. The checks of fly reach the app on its internal host and never go through
  the zone.

⚠️ **A skip rule takes the signed `POST /webhooks/contentful` on the api host out of the managed
rules.** Contentful rich text can match a managed injection rule, and the HMAC check of the api
authenticates that request. Without the skip, a block stops the PDS sync and the site builds, and it
gives **no message**. Each other path below `/webhooks/` still goes through the managed rules. When a
webhook stops, read Security Events before you read the code.

⚠️ **The rate limiting rules are NOT in the skip list, on purpose.** Do not add them.

**The managed rules** — the **OWASP Core Ruleset** is **not** on, on purpose: it gives many false
results, and the main thing that it would catch here is the text of the contact form. If you ever set
it on, use PL1, the High threshold (60), and the Log action, and never a stricter value.

**Super Bot Fight Mode** — **static resource protection stays off**, because it would give a
challenge to the CSS, JavaScript, and font requests of the site.

**The rate limiting rules.** The Pro plan permits two:

- `/api/contact` — it stays on **Block**. ⚠️ Never use a challenge action: the native POST path with
  no JavaScript cannot answer a challenge, and that would break the path for a browser with no
  JavaScript.
- A limit on a crawler on the site host, then a Managed Challenge. ⚠️ Do not use a much lower number
  than approximately 200 requests each minute: Pagefind gets a group of index files for each search,
  and Turbo gets a page early when the pointer goes to a link. Thus one true reader is much above a
  simple rate.

**Polish and Mirage stay off**, because each image already goes through `/cdn-cgi/image/*`, which
selects the format and the quality.

**A zone rule blocks the bots, and no code does.** Do not add an edge function for it. If the
referral traffic or the analytics look incorrect, read the custom rules before you read the code.

## How the two apps connect

The api has three route namespaces. `/widgets/*` gives HTML fragments, `/api/*` takes or gives
structured data at `KONA_API_URL`, and `/webhooks/*` takes the inbound webhooks.
`web/src/api-proxy.ts` proxies `/widgets/*` and `POST /api/contact` from the site host, and its
comments give the rules of that proxy.

- ⚠️ `API_TOKEN` must be in the secrets of the Worker in the dashboard, and it must **be the same as
  the token of the API**. If it is not, each widget gets a 401 on the full site.
- The **path alone** is the key of the edge cache: no query parameter, and no value for each user.
  Put each input of a widget in the **path**.

### Contact form (`POST /api/contact`)

⚠️ **A contact message must never go away. The Claude subject line is the only step that can fail
and be skipped.** Each other step fails **closed**. Refer to [`api/CLAUDE.md`](api/CLAUDE.md) for
the checks and the quarantine.

## The image mirror

The api copies each Contentful image asset into an **R2 bucket**, which its own custom domain in the
zone serves, and that host name is the source of each transformation. `AssetMirror` and
`Contentful#rewrite_image_urls` give the contract: the key of each object is the Contentful path,
with no change.

⚠️ **A difference between the two sides makes each image on the site 404, and nothing reports it.**
Such a difference is the wrong bucket, the wrong custom domain, a key shape that a person "improved",
or an `IMAGE_HOST` with a value before the backfill was complete. The order of the steps: the
bucket, the custom domain, and the mirror host in the Transformations list; then
a deploy of the api with the `R2_*` secrets; then `rake assets:backfill` to its end; and *only then*
a value for `IMAGE_HOST` in the build environment of web. The images are broken between the last two
steps, thus keep that time short. And never correct it with ctfassets in the list.

## The cross-app HTML contract (most important)

The API gives HTML fragments that **replace** a placeholder element in the static site. Thus the
markup of the two must have the same structure in the two apps.

- The **outermost element of the API fragment must have** `data-controller="live-update"` and
  `data-live-update-url-value`. Without them, it gets no new content after the first swap. ⚠️ It
  must **NOT** have `data-live-update-placeholder-value`: that flag means "I am an empty skeleton",
  and on a fragment it makes a short fetch failure **delete content that the page already shows**.
- Its tag, its CSS class names, and its DOM shape must be the same as in the placeholder.
- An **empty** response makes the controller **remove the element**. Thus the widget goes away and
  no skeleton stays on the page. An empty body is the "no data" answer, on purpose. Do not change it
  into markup. This applies in each condition. A non-2xx status and a network error are different:
  they remove **a placeholder only**.

⚠️ **Not each element on the web side is a skeleton.** `live_update_attrs(url, placeholder: false)`
marks an element that the build renders with **real content**, and the fragment then adds to that
content and does not fill an empty element. Today that is the upcoming-races section only: the build
writes it from `data/events.json`, and the api renders it again with the race-day weather and a
"Today's Race" section. Such an element must not have the placeholder flag, for the same reason as
the api fragment: a short fetch failure would delete content that is already correct. The helper
gives it the `static` flag in place of that, thus it gets the fragment at each connect. ⚠️ An api
fragment must never have the `static` flag: each swap would then fetch again, with no end. An **empty**
response still removes it, and that is the api saying that there is no upcoming race.

`api/spec/contracts/widget_markup_contract_spec.rb` compares the outer element of each pair. A
person keeps each element in it the same in the two apps.

⚠️ **Each api spec that reads a `web/` file needs that path in the `paths:` of `api.yml`.** That
workflow has a path filter, thus without the path no check runs on the edits that break the contract
most often.

The trending widget is on the home page and on a Page. ⚠️ An **entry page does not** show it, on
purpose: it already has "More Reports From This Race", "You May Also Like", and the Previous and Next
cards. Do not add it to an entry page.

The shared CSS is in `web/source/stylesheets/components/`. The fragments of the api use the classes
of `_collection.scss`, `_entry.scss`, `_event.scss`, `_stats.scss`, and `_weather.scss`:
approximately 38 classes, and also `sr-only`. The two apps own those five files together. A list of
the classes here would become incorrect at the first change to a widget.

⚠️ **When you change the markup, the class names, or the DOM shape of a widget, edit the web
placeholder and the api view together.**

## The analytics of a card click

Each link into an article carries the Plausible class names of one custom event, **`Article
Click`**, with a `section` property that names the module that holds the link. Thus the dashboard
answers "where does a reader enter an article from, inside the site". The tracking script also adds
a `url` property with the destination, and the `event:page` dimension of Plausible is the page that
the reader clicked on. Thus neither one needs a property.

**The heading of the section IS the value of `section`, word for word**, and the partial reads it
from the same `title` local that it renders. Thus the dashboard reads as the page reads.

⚠️ **A new heading is a new line in the dashboard, and that is the purpose.** The old line stops and
the new one starts on the day of the deploy, thus you can compare the two and see what the new words
did. Nothing joins them again, thus a heading that you change and then change back gives three
lines. Change a heading when you want that measurement.

Three values are overrides, because their heading cannot be the value:

| `section` | Module |
|---|---|
| `Blog List` | The blog index and each tag archive. ⚠️ Those pages have **no** section heading: the `<h1>` is the name of the page, and for a tag archive that is the name of the tag. Thus the heading would make one value for each tag, and `event:page` already gives you that. |
| `Recent Articles (404)` | The 404 page. ⚠️ Its heading is the same as the one on the home page. The plain heading would merge the two, and `event:page` cannot separate them: a 404 is served at whatever URL the reader asked for. |
| `Article Body` | A link to an article in the intro or the body of an article page or of the page of a Short, because the text has no heading. Pages and the cards of a list do not get it. |

⚠️ **The classes go on each `<a>`, and never on the card.** The tracking script walks **four nodes
up** from the click at the most, and it looks for the anchor and the tagged element together. From
the "Continue reading" link and from the date permalink, the `<article>` is outside that range. Such
a link then sends nothing, and it gives no message.

⚠️ The trending fragment is at the edge for an hour. Thus a change to these classes needs the manual
`widgets` tag purge, or the cards keep the old markup until that TTL ends.
