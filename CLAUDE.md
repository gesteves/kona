# Kona — monorepo guide

This file covers the **monorepo shape and the contract between the two apps**. For app-specific
commands and conventions, read the nearest `CLAUDE.md`:

- [`web/CLAUDE.md`](web/CLAUDE.md) — Middleman static site (the blog).
- [`api/CLAUDE.md`](api/CLAUDE.md) — Rails API serving dynamic widgets.
- [`utilities/contentful/CLAUDE.md`](utilities/contentful/CLAUDE.md) — Contentful migrations + taxonomy.
- [`utilities/maps/CLAUDE.md`](utilities/maps/CLAUDE.md) — static map generation from GPX tracks.

Work on one app from inside its own directory; each has its own `Gemfile`, `.env.example`, and
test suite.

## Repo layout

| Path | What | Deploy |
|---|---|---|
| `web/` | Middleman 4 static site (Ruby 4.0.6). Builds the Contentful-powered blog. | Cloudflare Workers (`kona-web`) |
| `api/` | Rails 8.1 API (Ruby 4.0.6). Serves HTML "widget" fragments embedded into the static pages at runtime, plus a Sidekiq `worker` process. | fly.io (`kona-api`: `app` + `worker`), behind Cloudflare |
| `redis/` | `fly.toml` for `kona-redis`, the API's Redis (cache + Sidekiq queues). | fly.io |
| `utilities/` | Local-only tools. Never deployed — see below. | — |

Each app has its own Redis via its own `REDIS_URL`: `api/` uses `kona-redis`, `web/` uses a
separate Upstash instance. Distinct keyspaces, no shared data.

There is also a **Cloudflare R2 bucket** mirroring Contentful's image assets, served from its own
custom domain in the zone. No config in the repo — dashboard-side, populated by the api. See
**The image mirror**.

### `utilities/` — local-only tools

⚠️ **The point of this directory is that it isn't deployed.** `web.yml` and `api.yml` are
path-filtered on `web/**` / `api/**`, so a change under `utilities/` builds nothing, deploys
nothing, and never fires the Web deploy's `Cache-Tag: site` edge purge. **Don't make `web/` or
`api/` depend on anything here** at build or request time. `.github/workflows/utilities.yml` runs
the checks that exist (today: `utilities/maps/`'s rspec suite) without deploying.

- **`utilities/contentful/`** — content migrations + the SKOS taxonomy toolkit.
- **`utilities/maps/`** — standalone Ruby/Rake app rendering GPX tracks as static PNG cover
  images via Mapbox. The PNGs are uploaded to Contentful by hand.
- **`utilities/aqi-map/`** — standalone Sinatra app serving one local page: a Mapbox map of
  historical PurpleAir readings, screenshotted for a post's cover image. Sketch quality and
  **not deployable** — it binds `127.0.0.1` and proxies a PurpleAir key with no auth of its own.
  ⚠️ It **duplicates** the EPA correction and AQI conversion from `api/app/services/purple_air.rb`
  (`utilities/` must not depend on `api/`), so a fix there won't reach it. The copy is isolated in
  `utilities/aqi-map/lib/epa_aqi.rb` so the two can be diffed directly, and
  `spec/epa_aqi_check.rb` pins it with golden vectors — computed from the **published equation**,
  not from either implementation, so a shared bug can't pass. `utilities.yml` runs it.

## Local development

Two commands, and **which one you run is the choice of API target** — there is deliberately no flag:

```bash
overmind start                    # web :4567 + api :3000, site → the local api
cd web && bundle exec middleman   # web only, site → the deployed api
```

`overmind` is a prerequisite (`brew install overmind`; it pulls in tmux). It reads `Procfile.dev`
and `.overmind.env`, and child processes inherit the latter's `KONA_API_URL`/`SITE_URL`. Since
dotenv never overwrites an already-set variable, that's the whole mechanism — and it's why the
plain `middleman` command still reaches production off `web/.env`. `overmind restart web` restarts
one process; `overmind connect api` attaches a real TTY, so `binding.break` works. Sidekiq is
opt-in (`overmind start -l web,api,worker`): no widget endpoint enqueues a job.

Ports: 4567 Middleman, 3000 Rails, 8787 `wrangler dev`, 6379 Redis. The api logs to
`api/log/development.log`, **not** to its overmind pane.

Two transients that look like bugs and aren't:

- `overmind kill` can leave `.overmind.sock` behind, and the next `overmind start` then refuses
  with "it looks like Overmind is already running". Delete the socket. Ctrl-C or `overmind quit`
  exits cleanly instead.
- A burst of `ActionController::RoutingError`s on the api's **first** page load, self-healing on
  refresh. `routes.rb` ends in a `*unmatched` catch-all, so once routes are loaded nothing can
  raise this — it means the route set was momentarily empty. Rails dev has
  `enable_reloading = true` / `eager_load = false`, so the first request redraws the routes while
  Puma's other two threads are already serving the rest of the page's five widget fetches. It is
  a dev-mode reload race, not the proxy.

⚠️ `Procfile.dev` pins `PORT=3000` for the api. Overmind injects a Heroku-style `PORT` per process
(5000, then +100 each) and `api/config/puma.rb` reads it, so without the pin the api comes up on
5100 and every widget 502s against a `KONA_API_URL` that looks correct.

⚠️ `/widgets/*` and `POST /api/contact` reach `middleman server` through
`web/lib/utils/dev_api_proxy.rb`, a dev-only Rack middleware — the static site has no page behind
those paths, so without it every widget collapses locally. It is **not** a port of
`web/src/api-proxy.ts` and must not become one: that file's invariants exist to make one shared
edge cache entry safe for many viewers, and there is no edge here. `/pa/*` and the OG cards are
deliberately not proxied; they need `wrangler dev` (see [`web/CLAUDE.md`](web/CLAUDE.md)).

## Duplicated across the two apps

Beyond the aqi-map copy above, five helpers exist in both `api/` and `web/` because they render
markup that ends up on the **same page** — the static build renders an article, and the api
re-renders the same summary text into the trending/related fragments swapped into it. Drift
changes typography or link behavior mid-page:

| Logic | api | web |
|---|---|---|
| `markdown_to_html` + `smartypants` | `helpers/markdown_helper.rb` | `helpers/markdown_helpers.rb` |
| `clock_icon_svg` | `helpers/icons_helper.rb` | `helpers/icon_helpers.rb` |
| `article_permalink_timestamp` | `helpers/articles_helper.rb` | `helpers/article_helpers.rb` |
| Canonical article path | `services/article_attributes.rb` | `lib/data/contentful.rb` |
| `units_tag` / `add_unit_data_attributes` | `helpers/markup_helper.rb` | `helpers/markup_helpers.rb` |
| `fix_degrees` | `helpers/text_helper.rb` | `helpers/text_helpers.rb` |

⚠️ `Api::MarkupHelper#render_summary_body` is a deliberately reduced `render_body`, but the
reductions are load-bearing in one direction: it **must** keep applying `fix_degrees` and
`mark_affiliate_links`. Dropping the latter silently strips the `rel="sponsored nofollow noopener"`
disclosure from an affiliate link that carries it everywhere else on the same page.

⚠️ `open_external_links_in_new_tabs` genuinely **diverges**: web skips same-host links, the api
opens every absolute link, on the assumption that card bodies only ever link off-site. Nothing
enforces that assumption.

## Code style

- **Comments are concise.** Document what a method or function does, and its parameters and
  return value, using RDoc/YARD (Ruby) or JSDoc (JS/TS). Don't document what the code already
  says.
- **Don't write history.** No changelogs, migration narratives, "this used to be…", benchmark
  transcripts, or records of approaches that were tried and reverted. Those belong in git.
- **Rationale earns its place only when it's load-bearing** — an invariant that isn't obvious
  from the code and that a plausible "cleanup" would break. One or two sentences, flagged with
  ⚠️. Anything longer belongs in a `CLAUDE.md`.
- Same for these `CLAUDE.md` files: they carry what an agent can't discover by reading the code —
  cross-app contracts, dashboard-side config, and non-obvious invariants. Keep them short.
- Never hardcode production hostnames (below).

## Production domains — never hardcode

⚠️ **Never hardcode the production hostnames anywhere** — code, comments, docs, examples, tests,
CI config. This covers the public site host, the public API host, the admin host, and the fly.io
origin host. They come from configuration:

- API origin: `KONA_API_URL` (web build, `/widgets/*` proxy, api's CI Slack link).
- Public API host: `API_HOST` (api — the route constraint that keeps the owner-facing routes off
  it; host only, no scheme).
- Site URL: `URL` (web), `SITE_URL` (api).
- Whoop redirect: `WHOOP_REDIRECT_URI` (⚠️ must name the **admin** host — the callback route
  doesn't exist on the public API host).

Where a placeholder is genuinely needed, use `https://<your-app-host>/…`.

The **root `README.md` is the one exception**: its opening line links the site by name, which is
what a README is for, and nothing reads it. The rule is about hostnames that *behave* — anything a
build, a request, a test, or a workflow resolves.

## Cloudflare sits in front of everything

⚠️ **Nothing in this repo configures the zone.** It's all dashboard-side, invisible to `grep`, and
several code paths hard-depend on it. Assume every production request traverses Cloudflare before
reaching the Worker or fly, and check the zone before concluding something is a code problem.

⚠️ Every rule below names hostnames **typed by hand and never validated**. A misspelled host saves
cleanly, shows as Active, and matches nothing — silently. This has already happened once. Paste
hostnames from the zone's DNS records, then confirm the rule's Events counter is non-zero.

- **Client IP** — `CF-Connecting-IP` is the only real visitor IP; fly's `Fly-Client-IP` is a
  Cloudflare PoP. Read by `api/config/initializers/rack_attack.rb` and `web/src/log.ts`. It's
  spoofable by anything hitting an origin directly, so it may key throttling and logging but must
  **never** gate a ban.
- **Images** — Cloudflare Images serves every transformation from `<IMAGES_URL>/cdn-cgi/image/…`,
  fetching the source from the R2 mirror. Requires **Transformations** enabled with the mirror
  host on the source allowlist.
  ⚠️ **Never add `*.ctfassets.net` to that allowlist.** Its absence is load-bearing: it makes a
  bad or missing `IMAGE_HOST` fail loudly. Allowlisting ctfassets instead renders a perfect-looking
  site straight off Contentful while draining the metered bandwidth the mirror exists to protect.
- **OG cards** — pages with no cover image get an `og:image` rendered on demand by the `kona-web`
  Worker at `<page path>og.png` (`web/src/og.ts`). Needs the **Workers Paid** plan (~100 ms CPU
  per render vs Free's 10 ms limit). Details in [`web/CLAUDE.md`](web/CLAUDE.md).
- **Managed transform** — "Add visitor location headers" must be on, or `CF-IPCity`/`CF-Region`
  are absent and geo logging degrades to country-only.
- **`/cdn-cgi/*` never reaches an origin.** Cloudflare answers it at its own edge.

### Cache Response Rules (tagging)

Deploys do **not** self-invalidate at the edge, so invalidation is explicit: a rule tags responses
`Cache-Tag: site`, and `.github/workflows/web.yml` purges that tag on every deploy.

```
(http.host eq "<site host>" and not starts_with(http.request.uri.path, "/cdn-cgi/"))
or
(http.host eq "<api host>" and (
  starts_with(http.request.uri.path, "/widgets/articles/")
  or starts_with(http.request.uri.path, "/widgets/events/")
))
```

The first branch is the whole static build. The second is the widget fragments that render
**Contentful** content, matched by namespace — articles and events are Contentful content types,
so anything under those prefixes is Contentful-backed by definition, and a new widget there is
covered automatically. A Contentful publish dispatches a deploy, which fires the purge, so those
widgets can't serve pre-edit content for their full edge TTL.

⚠️ **Never collapse this to a path-only or host-only match, and never widen the second branch to
`/widgets/`.** A purge drops a fragment's `stale-while-revalidate` / `stale-if-error` copies along
with the fresh one, and those are what keep widgets rendering through a fly outage. Blanket-tagging
every widget would mean a Contentful publish landing mid-outage collapses all of them site-wide.
The live-data widgets (`weather/current`, `activity-stats`, `whoop`, `plausible/pageviews/:id`)
render nothing from Contentful and sit in their own namespaces, which is what keeps them out.

⚠️ **The OG card paths are deliberately NOT excluded from the first branch.** Article cards are
content-addressed and never need purging, but **listing pages** (blog index, tag archives, home)
aren't Contentful entries, so their card URL is fixed forever while their `og:title` can change.
For those, the deploy purge is the only automatic refresh — and it's automatically correct, since
the thing that changes such a title is a Contentful publish.

⚠️ **The image-mirror host is deliberately absent from both branches.** Its objects are immutable
and content-addressed, so there's nothing a purge could fix, while tagging them would dump the
entire image cache on every content publish.

A **second** rule tags every widget on the api host `widgets`, ordered **after** the `site` rule
(never First — if Cloudflare stops at the first match, an earlier `widgets` rule would silently end
the deploy purge for the Contentful-backed widgets). It exists solely to make a manual
`POST /zones/<id>/purge_cache` with `{"tags":["widgets"]}` one call instead of ~60.

⚠️ **Never wire `widgets` into the deploy purge.** That workflow purges `{"tags":["site"]}` and
must keep purging only that, for the reason above. Reach for the manual lever when a widget's
cached copy is wrong in a way waiting won't fix — a `cache_widget` TTL change (a cached fragment
keeps the `CDN-Cache-Control` it was *stored* with) or a markup change that must land in step with
the web placeholder.

⚠️ A **Contentful-backed widget added under a NEW top-level namespace needs this rule edited in
the dashboard**, and nothing in the repo will remind you — it will go stale forever, silently.

(Tags must come from a Cache Response Rule; a `Cache-Tag` response header is not consumed by
Cloudflare. These rules run in the `http_response_cache_settings` phase, after the origin response
and including Worker subrequests, which is what puts the widget fragments in reach.)

### Cache Rules (edge TTL)

Exactly one, scoped far more narrowly than it looks like it needs to be:

```
http.host eq "<site host>"
and not http.request.uri.path contains "."
and not starts_with(http.request.uri.path, "/cdn-cgi/")
and not starts_with(http.request.uri.path, "/widgets/")
and not starts_with(http.request.uri.path, "/api/")
and not starts_with(http.request.uri.path, "/pa/")
```

Eligible for cache; **Edge TTL: ignore cache-control, 1 year**; **Browser TTL: respect origin**.

What it buys is **archive residency** — most URLs here are old posts getting a handful of hits per
PoP, which fall out of a short edge TTL between visits. The TTL is a ceiling, not a promise: PoPs
evict under LRU regardless, so it only ever stops being the binding constraint. Why each exclusion:

- **`contains "."`** isolates HTML (page URLs are extensionless), leaving fingerprinted assets on
  the `immutable` policy they already declare correctly. It's also what keeps the **OG cards** out
  without a clause of its own — which is why that route carries an extension.
- **`/widgets/`, `/api/`, `/pa/`** — three of the four `run_worker_first` route families live on
  the site host and are extensionless. A 1-year TTL would pin every widget indefinitely, and
  caching `/pa/*` would corrupt analytics. **A new `run_worker_first` entry needs a matching
  exclusion here**, and nothing in the repo will remind you.

⚠️ **Never add a cache rule on the api host.** Widget TTLs come from the origin's own
`CDN-Cache-Control`; a cache rule would override them wholesale.

⚠️ **The deploy purge is the only thing standing between a 1-year TTL and a page pinned for a
year.** The rule ignores `Cache-Control` outright, so a purge that silently matches nothing leaves
the edge serving that copy essentially forever. Treat a purge failure in `web.yml` as a page-level
outage.

### Zone security rules

The zone is on Cloudflare **Pro**, so WAF **Managed Rules** and **Super Bot Fight Mode** apply
zone-wide — **including the api host**, where nearly all traffic is machine-to-machine and looks
exactly like what those features exist to block.

⚠️ **The skip rule must exist *before* those features are enabled**, or every widget 403s site-wide
the moment SBFM goes on.

Custom rules, evaluated top to bottom. The BLOCK rules stay above the skip, and the skip does not
tick "All remaining custom rules":

| # | Rule | Expression | Action |
|---|---|---|---|
| 1 | Abusive Linux crawler with fake Google referrer | desktop-Linux Chrome UA + `google.com` referer | Block |
| 2 | Block scanner noise | path families no host in the zone serves (see below) | Block |
| 3 | Block access to original images | `http.host eq "<image host>" and not any(http.request.headers["via"][*] contains "image-resizing")` | Block |
| 4 | Skip bot protection off the admin host | `http.host ne "<admin host>"` | Skip → all managed rules **and** all SBFM rules |

**Rule 1** is knowingly over-broad: those conditions also match a real person on desktop Linux
clicking a Google result, and blocking them is an accepted cost. The bot gets through managed,
non-interactive, **and** interactive challenges, so UA + referer is the only thing left that stops
it. Don't narrow it to challenges — that's the approach that already failed.

**Rule 2** is one big `or` over `lower(http.request.uri.path)`, matching by *family*: known-bad
extensions (`.php`, `.env`, `.sql`, `.yml`, `.pem`, `.key`, …), tool/framework prefixes (`/wp-`,
`/cgi-bin/`, `/actuator/`, `/phpmyadmin/`, `/k8s/`, `/terraform/`, `/secrets/`, `/config/`,
`/deploy/`, `/flask/`, `/pki/`, `/home/`, `/analytics/`), secret-material filenames (`credential`,
`cognito`, `/id_`), any **dot-segment anywhere** (`contains "/."`, with `/.well-known/` exempted),
and anything outside `GET`/`HEAD`/`POST`.

⚠️ Scanners **percent-encode the dots** (`/terraform/%2eenv%2estaging`) to walk past extension
matching, so the rule also blocks a bare `contains "%2e"`. Whether that or the decoded form fires
depends on the zone's **Normalize incoming URLs** setting, and Security Events shows the raw path
either way — so you cannot tell which form the rule saw. Every clause is chosen to match in *both*
forms; don't drop either as redundant.

⚠️ The prefixes are `starts_with`-anchored and the rule is zone-wide. `activate :directory_indexes`
means pages are served at `/<slug>/`, so a top-level page slugged `config`, `home`, `analytics`, or
`deploy` would be blocked by its own prefix clause — check `data/pages.json` before adding a prefix,
and remember this if a new page ever 403s. Every clause must also stay false for the api host
(`/widgets/`, `/api/`, `/webhooks/`, `/whoop/`, `/auth/`, `/login`, `/sidekiq`, `/up`) and for the
R2 key shape (`{space}/{asset id}/{token}/{filename}`).

**Rule 3** tells "Cloudflare Images fetching a source" apart from "someone typing the URL in" via
the `image-resizing` marker Cloudflare puts in `Via`.

⚠️ **Never simplify it to a bare host block** — the transformation's own fetch traverses the rules
pipeline, so a blanket block 403s **every image on the site**. After editing, verify **both**
directions: a direct `curl` must 403, *and* a page must still render its images.

⚠️ **It is friction, not a boundary**, and both gaps are measured: `Via` is an ordinary request
header (`curl -H 'Via: 1.1 image-resizing'` returns 200), and the transformation endpoint on the
site host takes an arbitrary width, so `/cdn-cgi/image/width=7728/<source>` returns a full-resolution
render. The only thing that would bound the maximum obtainable resolution is **capping the stored
master** (mirroring `?w=2560` instead of the original).

**Rule 4** is one condition rather than a per-host path allowlist because **the api app enforces
the split itself**: `API_HOST` in `api/config/routes.rb` draws the owner-facing routes (`/login`,
`/logout`, `/auth/*`, `/whoop/auth`, `/whoop/callback`, `/sidekiq`) only off the admin host, so the
public api host answers nothing but `/up` and the three machine namespaces.

⚠️ **That route constraint is the whole reason this rule is safe.** An owner-facing route drawn
outside it lands on a host where managed rules and SBFM are skipped, and nothing in the zone would
notice. `api/spec/requests/host_constraints_spec.rb` pins both directions.

⚠️ **It's a denylist, so any hostname added to the zone is unprotected by default** — a staging
subdomain, a second origin, a new service. The earlier allowlist form failed in the opposite and
much louder direction. Name new hosts here deliberately.

Why the skip is needed at all, host by host:

- **Site host** — SBFM was blocking **feed readers and Open Graph scrapers**. "Verified bots:
  Allow" covers Googlebot/Bingbot but not Slack/Mastodon/Discord unfurlers or RSS clients, which
  are exactly the traffic a blog wants. Those unfurlers are also the only consumers of the OG
  cards. ⚠️ The host is not purely static: `run_worker_first` claims `/widgets/*`, `/api/contact`,
  `/pa/*`, and the card paths, and `POST /api/contact` is a real intake carrying arbitrary user
  prose. Managed rules were never the layer defending it — the honeypot, Turnstile, Akismet, the
  length caps, and the `contact/ip` throttle are. Don't let this skip become a reason to thin
  those out.
- **Image host** — the source fetch has no browser fingerprint at all, the textbook "definitely
  automated" verdict, so SBFM would collapse every image at once.
- **Public api host** — `web/src/api-proxy.ts` sends only an `authorization` header,
  deliberately (the cache entry must be byte-identical for every viewer), which is the same
  "definitely automated" fingerprint. `/api/` also covers the build-time callers. `/webhooks/`
  carries unattended POSTs of arbitrary Contentful rich text that will trip a managed injection
  rule sooner or later; both are HMAC-verified, so managed rules add nothing. ⚠️ A block there
  fails **silently** — nothing surfaces an error, the PDS sync simply stops happening.
- **Admin host** — the one host left protected, and the only one whose traffic is a real browser
  driven by one person: Google sign-in, the Sidekiq UI, the Whoop OAuth round-trip. A managed
  challenge there is survivable in a way it is nowhere else. ⚠️ Point external uptime checks at
  `/up` on the **public** host; fly's own checks reach the app on its internal host and never
  traverse the zone at all.

⚠️ **Rate limiting rules are deliberately NOT in the skip list.** Don't add them.

**Managed rules** — deploy the Cloudflare Managed Ruleset with the action overridden to **Log**,
read Security Events for a week, then switch to defaults. The **OWASP Core Ruleset** is
deliberately **not** deployed: high-noise, and the main thing it would catch here is the contact
form's own prose. If ever enabled: PL1, threshold High (60), action Log — never tighter.

**Super Bot Fight Mode** — definitely automated: Block; likely automated: Managed Challenge;
verified bots: Allow; JS detections: on; **static resource protection: off** (it would challenge
the site's own CSS/JS/font requests). ⚠️ It does not replace custom rule 1 — that scraper walks
through interactive challenges.

**Rate limiting rules** (Pro allows 2):

- `/api/contact` — stays on **Block**. ⚠️ Never a challenge action: the no-JS native POST path
  can't solve one by definition, which would break the progressive-enhancement fallback.
- Site-host crawler brake — GETs/HEADs outside `/cdn-cgi/`, per IP, ~200 req/min → Managed
  Challenge. ⚠️ Don't tighten much below that: Pagefind fetches a burst of index chunks per
  search and Turbo prefetches on hover, so one real reader sits well above a naive rate.

**Other zone settings**, deliberate but not load-bearing: Smart Tiered Cache on, Page Shield
script monitoring on, Early Hints / HTTP/3 / 0-RTT / Crawler Hints on. **Polish and Mirage stay
off** — every image already goes through `/cdn-cgi/image/*`, which picks format and quality.

**Bot blocking is a zone rule, not code.** The `block-bots` edge function was deleted (`3c4e0044`);
don't reintroduce it. If referral traffic looks wrong, read rule 1 before the code.

## How the two apps connect

The API's routes split by namespace: `/widgets/*` returns HTML fragments (proxied), `/api/*`
accepts or returns structured data (hit directly at `KONA_API_URL`, except `POST /api/contact`),
and `/webhooks/*` receives inbound webhooks. The web build reads two at build time:
`GET /api/standard-site` and `POST /api/icons`.

1. Browser requests `/widgets/*` (or `POST /api/contact`) on the main site.
2. `run_worker_first` in `web/wrangler.jsonc` claims those paths, so they invoke Worker code
   rather than being served from the static asset layer.
3. `web/src/api-proxy.ts` proxies to `KONA_API_URL`.
4. The upstream fetch is made cacheable (`cf: { cacheEverything: true }` — widget URLs are
   extensionless, so Cloudflare's extension-based default would cache nothing) and its TTL comes
   entirely from the origin's `CDN-Cache-Control` (RFC 9213). One cached copy serves all viewers.
   ⚠️ The entry is cached under the **api** hostname, which is why the `site` tag rule is scoped
   to that host.

⚠️ The proxy claims `/api/contact` **explicitly, not `/api/*`**. Don't broaden it, or you'd expose
`POST /api/location`, `POST /api/icons`, and `POST /api/build` (which ships a production deploy)
to the browser with the injected bearer.

Proxy invariants — don't break these:

- Forwards only `accept` (contact path only) and **injects** a constant
  `Authorization: Bearer <API_TOKEN>`; the client's own `authorization` is dropped. The token is
  the same for every viewer, so every upstream request is identical → one shared cache entry.
  ⚠️ `API_TOKEN` must be in the Worker's dashboard secrets and **match the API's**, or every
  widget 401s site-wide.
- Passes the origin's `Cache-Control`, the `ETag`/`Last-Modified` validators, and the **`Age`**
  of the edge-cached copy through. ⚠️ **`Age` is load-bearing.** The browser policy is
  `max-age=0, stale-while-revalidate=N`, and RFC 9111 has the browser measure that window from
  the response's age; without it every viewer gets a full-length window stacked on however long
  the edge already held the copy. On a counter that only goes up, that reads as the number going
  *down*.
- Does **not** forward `CDN-Cache-Control` downstream.
- Keys the edge cache on **path only** — no query params, no per-user vary. Keep widget inputs in
  the **path**.
- Returns an empty, briefly-cached `502` if the upstream throws, so an origin blip collapses the
  widget rather than pinning an error.
- **Contact only:** forwards the real visitor IP/UA/geo as `X-Kona-Client-*` (the origin can't
  see them otherwise — the zone rewrites `CF-*` to describe the Worker's egress) and the
  `Location` header for the no-JS redirect. The API uses these for Akismet, the rate limit, and
  the notification email — **never** for a ban.

### Contact form (`POST /api/contact`)

The form is a **web partial** (`source/partials/_contact_form.html.erb`), **not** raw HTML in the
Contentful body — SmartyPants would curl the quotes in its attributes and corrupt the field names
and Stimulus wiring. The intro copy stays in Contentful.

`Api::ContactController` drops honeypot hits (the hidden `comment` field) and enqueues a
`ContactMailJob`, which spam-checks with **Akismet** and emails via **Resend** (an HTTPS API — fly
blocks outbound SMTP) with `Reply-To` set to the sender. **Progressively enhanced**: the `contact`
Stimulus controller posts via `fetch` with `Accept: application/json` (→ 204/422, toast, no
navigation); without JS the native POST sends `Accept: text/html` (→ 303 to `/contact/success`).
Same endpoint, same validation for both.

Defense layers: honeypot + Akismet (both paths), server-side length caps, a per-visitor
rack-attack throttle on the forwarded `X-Kona-Client-IP`, and **Cloudflare Turnstile**. ⚠️
Turnstile needs JS, so it's verified **only on the JSON path**. Turnstile and Akismet both fail
open when *unconfigured*; when Akismet *is* configured it fails **closed** — an outage retries the
intake job rather than delivering an unchecked message.

## The image mirror

Every image is a Cloudflare Images transformation, and Cloudflare fetches the untransformed
**source** from whatever host the URL names. A source outside the zone can't use Tiered Cache or
Cache Reserve, so every PoP independently pulled the full-size original from Contentful and
re-pulled it on eviction. So the assets are mirrored into an **R2 bucket** served from its own
custom domain in the zone, and that hostname is the transformation source.

The two apps meet **only through the shape of a URL** — no request between them, no imports,
neither validates the other:

| | Who | What |
|---|---|---|
| Writes | `api` — `AssetMirror` + `AssetSyncJob` on the asset-publish webhook, plus `rake assets:backfill` | An R2 object keyed on Contentful's path **verbatim**: `{space}/{asset id}/{token}/{filename}` |
| Reads | `web` — `Contentful#rewrite_image_urls` at build time, gated on `IMAGE_HOST` | Swaps **only the host**, so the emitted path is that same key |

⚠️ **Both sides match every `*.ctfassets.net` host and must keep matching the same set.**
Contentful serves plenty of ordinary image assets from `downloads.ctfassets.net`, which doesn't
support the Images API at all. Narrowing either side to `images.ctfassets.net` leaves those
hitting Contentful forever, silently.

⚠️ **A mismatch — wrong bucket, wrong custom domain, a "tidied" key shape, `IMAGE_HOST` set before
the backfill finished — 404s every image on the site, and nothing reports it.** Rollout order:
bucket + custom domain + the SBFM skip + the mirror host on the Transformations allowlist → deploy
the api with the `R2_*` secrets → `rake assets:backfill` to completion → *only then* set
`IMAGE_HOST` in the web build env. The window between the last two steps is when images are broken,
so keep it short — and never "fix" it by allowlisting ctfassets.

Three consequences:

- **The mirror is publish-only; unpublish and delete are ignored on purpose.** `web` reads
  Contentful with a **preview** token, so an unpublished asset is still referenced by built pages.
  Objects are immutable anyway, so nothing needs invalidating.
- **Blurhashes go through the mirror too** (`encode_blurhash` resizes via `cdn_image_url` like
  every other image). ⚠️ It must ask for an explicit `fm:` — with no format Cloudflare returns the
  source format, and a libvips without that loader fails the decode into a `rescue`, i.e. silently
  no placeholder.
- **`IMAGE_HOST` is required everywhere, including locally. It is not a rollback switch.** The
  rewrite still no-ops when it's blank, but the allowlist names only the mirror host, so an unset
  `IMAGE_HOST` leaves every image pointed at ctfassets and **403s the lot**. Rolling the mirror
  back means changing the allowlist in the dashboard first.
- **Direct access to the mirrored originals is blocked** by custom rule 3 — friction, not a
  boundary (see above). The mirror stores true originals today (1.39GB, including a dozen 20–38MB
  camera JPEGs), so that's what a determined caller can still reach.

## The cross-app HTML contract (most important)

The API returns HTML fragments that **replace** placeholder elements in the static site, so their
markup must stay structurally in sync across the two apps.

`web/source/javascripts/stimulus/controllers/live_update_controller.js` reads
`data-live-update-url-value`, fetches the fragment, and on a **non-empty** response replaces the
entire placeholder element. It fetches on connect when the element is a **placeholder**
(`data-live-update-placeholder-value="true"`), or when the content for that URL is more than a
minute old; and again on tab `visibilitychange` under the same floor. That clock is module-scoped
and **keyed by URL**, so it outlives both the placeholder→fragment swap and a Turbo back/forward
**restoration visit** — which re-renders a cached snapshot containing the *fragment* and never
revalidates it. Without the clock, a restored widget would display whatever it showed when the
user last left: a view counter visibly going backwards.

Consequences:

- The API fragment's **outermost element must itself carry** `data-controller="live-update"` +
  `data-live-update-url-value`, or it stops refreshing after the first swap. ⚠️ It must **NOT**
  carry `data-live-update-placeholder-value`: that flag means "I am an empty skeleton", and on a
  fragment it would make a transient fetch failure **delete already-rendered content**.
- Its tag, CSS class names, and DOM shape must match the placeholder.
- An **empty** response makes the controller **remove the element**, collapsing the widget rather
  than leaving a stuck skeleton. An empty body is the intentional "no data" signal — don't "fix"
  it by returning markup. This is unconditional; a non-2xx or network error, by contrast,
  collapses **only** a placeholder.

Placeholders build the shared attributes with `live_update_attrs`
(`web/lib/helpers/site_helpers.rb`); the API views build the matching outer element with
`live_update_url`.

The **web half** is pinned by `web/test/browser/controllers/live_update.test.js`. The two sides are
compared against each other by `api/spec/contracts/widget_markup_contract_spec.rb`, which reads
both files across the monorepo and asserts the placeholder and the fragment agree on tag, classes,
and `data-nosnippet`. It only checks the outer element — everything inside it is still kept in sync
by hand.

⚠️ That spec lives in the api but reads `web/`, and `api.yml` is path-filtered, so the placeholder
paths it reads are listed in that workflow's `paths:` **on purpose**. Without them the contract
would go unchecked on exactly the edits most likely to break it. The spec fails if the two lists
drift.

| Widget | web placeholder | api view | endpoint |
|---|---|---|---|
| Activity stats | `source/partials/placeholders/_stats.html.erb` | `views/widgets/activity_stats/show.html.erb` | `/widgets/activity-stats` |
| Whoop | `source/partials/placeholders/_whoop.html.erb` | `views/widgets/whoop/show.html.erb` | `/widgets/whoop` |
| Current weather | `source/partials/placeholders/_weather.html.erb` | `views/widgets/weather/current.html.erb` | `/widgets/weather/current` |
| Pageviews | `source/partials/article/_full.html.erb` (inline `span`) | `views/widgets/plausible/pageviews.html.erb` | `/widgets/plausible/pageviews/:id` |
| Upcoming races | `source/partials/_upcoming_races.html.erb` | `views/widgets/events/upcoming.html.erb` | `/widgets/events/upcoming` |
| Trending articles | `source/partials/placeholders/_trending.html.erb` | `views/widgets/articles/trending.html.erb` | `/widgets/articles/trending[/:id]` |
| Related articles | `source/partials/placeholders/_related.html.erb` | `views/widgets/articles/related.html.erb` | `/widgets/articles/related/:id` |

Shared CSS lives in `web/source/stylesheets/components/` — the api's fragments render classes from
`_collection.scss`, `_entry.scss`, `_event.scss`, `_stats.scss` and `_weather.scss` (around 38
classes in total, plus `sr-only`). Treat those five files as jointly owned; an enumeration here
would go stale on the first widget change.

Both sides build the live-update attribute cluster through a helper — `live_update_attrs` in
`web/lib/helpers/site_helpers.rb` and in `api/app/helpers/live_update_helper.rb` — rather than
writing it out per view. The api's omits `data-live-update-placeholder-value` deliberately, and
`api/spec/support/live_update_contract.rb` is a shared example, included by every widget request
spec, that fails if a fragment ever grows one.

⚠️ **When you change a widget's markup, class names, or DOM shape, edit the web placeholder and
the api view together** — and re-check the proxy constraints above.
