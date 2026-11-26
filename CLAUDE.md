# Kona — monorepo guide

This file gives the **contract between the two apps**, and the changes in the repo that need a
change in the Cloudflare zone. For the rules of one app, read the nearest `CLAUDE.md`:

- [`web/CLAUDE.md`](web/CLAUDE.md) — Middleman static site (the blog).
- [`api/CLAUDE.md`](api/CLAUDE.md) — Rails API serving dynamic widgets.
- [`utilities/contentful/CLAUDE.md`](utilities/contentful/CLAUDE.md) — Contentful migrations + taxonomy.
- [`.claude/rules/`](.claude/rules/) — the topics of one area. Each one loads with the files of its
  area.
- [`docs/cloudflare.md`](docs/cloudflare.md) — the reason for each rule of the zone.

Work on one app from its own directory. Each app has its own `Gemfile`, its own `.env.example`, and
its own test suite.

`redis/` holds the `fly.toml` of `kona-redis`. That Redis is the cache and the Sidekiq queues of the
api, and it is also the only copy of some records. Refer to [`api/CLAUDE.md`](api/CLAUDE.md).

⚠️ **A `.env` on your own machine must never hold a production value**, and this includes each
`REDIS_URL`. Both `.env.example` files give the reason. Use the local Redis that `overmind start`
runs.

### `utilities/` — local-only tools

⚠️ **Nothing here goes to production. Do not make `web/` or `api/` depend on a file here**, at
build time or at request time. `.github/workflows/utilities.yml` gives the reason.

⚠️ `utilities/aqi-map/lib/epa_aqi.rb` is a **copy** of the EPA math in
`api/app/services/weather/purple_air.rb`, and `utilities/race-weather/` loads that copy. A
correction in `purple_air.rb` does not reach the copy.

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

- ⚠️ **Write each comment, all the inline documentation, and each change to an agent document in
  ASD-STE100 Simplified Technical English, and keep it short.** An agent document is a `CLAUDE.md`,
  a file in `.claude/rules/`, or `docs/cloudflare.md`. This applies to new text and to a
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
  into an agent document.
- The same applies to each agent document. It holds what an agent cannot find in the code and
  cannot read with `cf`: a contract between the two apps, the reason for a dashboard configuration,
  and a rule that the code does not show. It does not copy a configuration. Keep each one short.
- **Put a topic where it loads only when an agent needs it.** A topic of one area of the code goes
  in `.claude/rules/`, with `paths:` frontmatter that names the files of that area. Claude Code then
  loads it only when it reads or edits one of those files. The reasons for the zone go in
  `docs/cloudflare.md`. A `CLAUDE.md` keeps the rules that apply to each change.
- **An edit to an agent document is not a routine step of a change.** Add a line only for a rule
  that has no place in the code.
- Never write a production host name in the code. Refer to the text below.
- ⚠️ **In `api/`, each user-facing word of the admin UI goes in `config/locales/en.yml`**, and
  never in an ERB file, a Ruby method, or a JS file. The rule, and what stays out of it, is in
  [`.claude/rules/admin-ui.md`](.claude/rules/admin-ui.md). This applies to the admin of `api/`
  only: `web/` is Middleman and has no Rails i18n.

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

⚠️ **No file in this repo configures the zone.** Read the live configuration with the `cf` CLI.
[`docs/cloudflare.md`](docs/cloudflare.md) gives the reason for each rule, and the order of the
steps for the image mirror. **Read it before you change the zone, and when you debug a 403, a 525,
an image that does not load, or an old page or widget from the cache.**

⚠️ Each change below needs a change in the zone, and no file in the repo tells you:

- A Contentful widget below a **new top-level namespace** of `/widgets/` needs a change to the
  `Cache-Tag` rule. Without it, the widget serves old content for all time.
- A **new top-level page** with the slug of a prefix that the scanner rule blocks, for example
  `config` or `deploy`, gives a 403.
- A **new host name** that machines call needs an entry in the SBFM skip rule. Without it, SBFM
  blocks its callers.

⚠️ When a request to an origin gives a **525**, read `fly certs list -a kona-api` first. Cloudflare
proxies each host, thus fly cannot renew a certificate without two more DNS records.

## How the two apps connect

The api has three route namespaces. `/widgets/*` gives HTML fragments, `/api/*` takes or gives
structured data at `KONA_API_URL`, and `/webhooks/*` takes the inbound webhooks.
`web/src/api-proxy.ts` proxies `/widgets/*` and `POST /api/contact` from the site host, and its
comments give the rules of that proxy.

- ⚠️ `API_TOKEN` must be in the secrets of the Worker in the dashboard, and it must **be the same as
  the token of the API**. If it is not, each widget gets a 401 on the full site.
- The **path alone** is the key of the edge cache: no query parameter, and no value for each user.
  Put each input of a widget in the **path**.

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

The shared CSS is in `web/source/stylesheets/components/`. The fragments of the api use the classes
of `_collection.scss`, `_entry.scss`, `_event.scss`, `_stats.scss`, and `_weather.scss`, and also
`sr-only`. The two apps own those five files together. A list of the classes here would become
incorrect at the first change to a widget.

⚠️ **When you change the markup, the class names, or the DOM shape of a widget, edit the web
placeholder and the api view together.**
