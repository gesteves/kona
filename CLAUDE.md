# Kona — monorepo guide

This file covers the **monorepo shape and the contract between the two apps**. For
app-specific commands and conventions, read the nearest `CLAUDE.md`:

- [`web/CLAUDE.md`](web/CLAUDE.md) — Middleman static site (the blog).
- [`api/CLAUDE.md`](api/CLAUDE.md) — Rails API serving dynamic widgets.
- [`utilities/contentful/CLAUDE.md`](utilities/contentful/CLAUDE.md) — one-off Contentful
  content migrations.
- [`utilities/maps/CLAUDE.md`](utilities/maps/CLAUDE.md) — static map generation from GPX tracks.

Work on one app from inside its own directory; each has its own `Gemfile`,
`.env.example`, and test suite.

## Repo layout

| Path | What | Deploy |
|---|---|---|
| `web/` | Middleman 4 static site generator (Ruby 4.0.6). Builds the Contentful-powered blog and serves all static pages. | Cloudflare Workers (`kona-web`) |
| `api/` | Rails 8.1 API (Ruby 4.0.6). Serves small dynamic HTML fragments ("widgets") embedded into the static pages at runtime, plus a Sidekiq `worker` process for background jobs (standard.site PDS sync). | fly.io (`kona-api`: `app` + `worker`) — behind Cloudflare |
| `redis/` | Config (`fly.toml`) for the `kona-redis` fly app — the API's dedicated Redis (cache + Sidekiq queues). | fly.io (`kona-redis`) |
| — | A **Cloudflare R2 bucket** mirroring Contentful's image assets, served from its own custom domain in the zone. No config in the repo — dashboard-side, populated by the api. See **The image mirror** below. | — (dashboard) |
| `utilities/` | Local-only tools, deliberately outside `web/` and `api/` so edits never trigger a deploy (see below). | — (never deployed) |
| `utilities/contentful/` | One-off Contentful content migrations + the taxonomy toolkit (Node scripts, run locally). | — (never deployed) |
| `utilities/maps/` | Static map generation: renders GPX tracks as PNG cover images via Mapbox (standalone Ruby/Rake app, run locally). | — (never deployed) |
| `utilities/aqi-map/` | Screenshot tool: a local fullscreen Mapbox map plotting historical PurpleAir AQI readings (standalone Sinatra app, run locally). | — (never deployed) |

Each app has its own Redis, configured via its own `REDIS_URL`: `api/` uses the dedicated
`kona-redis` fly app (`redis/fly.toml`); `web/` uses a separate Upstash instance. The apps
keep distinct keyspaces, so there's no cross-app data sharing to preserve.

### `utilities/` — local-only tools

⚠️ **The point of this directory is what it *isn't*: deployed.** `web.yml` and `api.yml` are
path-filtered on `web/**` / `api/**`, so a change under `utilities/` builds nothing, deploys
nothing, and — critically — never fires the "Web" deploy's `Cache-Tag: site` **edge purge**.
Anything local-only belongs here rather than inside an app; conversely, **don't make `web/` or
`api/` depend on anything in `utilities/`** at build or request time, or the isolation is gone.
`.github/workflows/utilities.yml` runs the checks that exist here (today: `utilities/maps/`'s
rspec suite) without deploying anything.

- **`utilities/contentful/`** — one-off content migrations (scripts that rewrite the content
  itself) plus the SKOS taxonomy toolkit. See
  [`utilities/contentful/CLAUDE.md`](utilities/contentful/CLAUDE.md) for the conventions (dry
  runs, skip-unchanged, inverses, rollout ordering).
- **`utilities/maps/`** — a standalone Ruby/Rake app (its own `Gemfile`, `.env`, and specs) that
  uploads GPX tracks to Mapbox as private vector tilesets and renders them as static PNG map
  images for race-report cover images. It used to live in `web/` (`lib/utils/static_map.rb`,
  `lib/tasks/maps.rake`) and was moved out for exactly the reason above. The PNGs are uploaded to
  Contentful by hand; nothing in `web/` reads them. See
  [`utilities/maps/CLAUDE.md`](utilities/maps/CLAUDE.md).
- **`utilities/aqi-map/`** — a standalone Sinatra app (its own `Gemfile` and `.env`, no specs)
  serving one local page: a fullscreen Mapbox map of what each PurpleAir sensor in view was
  reading at a given past timestamp, panned to a frame and screenshotted for a post's cover
  image. Built for one post and kept for the next — sketch quality, and **not deployable**: it
  binds `127.0.0.1` and proxies a PurpleAir key with no auth of its own. It renders with the same
  `outdoors-v12` default and the same `MAPBOX_STYLE_URL` variable as `utilities/maps/`, so its
  screenshots match the static GPX maps. ⚠️ It **duplicates** the EPA correction and AQI
  conversion from `api/app/services/purple_air.rb` (`utilities/` must not depend on `api/`), so
  a fix there will not reach it. See [`utilities/aqi-map/README.md`](utilities/aqi-map/README.md).

## Production domains — never hardcode

⚠️ **Never hardcode or mention the production hostnames anywhere in the code, including
comments, docs, examples, tests, and CI config.** This covers the public site host, the
API/admin host, and the fly.io origin host. They are environment-specific and must always
come from configuration:

- The API origin is read from `KONA_API_URL` (web build + `/widgets/*` proxy, and the api's own
  CI deploy-success Slack link).
- The site URL is read from `URL` (web).
- The Whoop redirect URI is read from `WHOOP_REDIRECT_URI`.

When an example or placeholder genuinely needs a host, use a generic stand-in like
`https://<your-app-host>/…` — never the real domain.

## Cloudflare sits in front of everything

⚠️ **The site runs entirely on Cloudflare, and the api origin is proxied through it**
(orange-cloud DNS): the public site is the `kona-web` Worker, and the api/admin host is fly.io
behind the zone. **Nothing in this repo configures the zone** — it's all dashboard-side, so it's
invisible to `grep` and easy to miss. Assume every production request traverses Cloudflare
before it reaches the Worker or fly, and check the zone before concluding something is a code
problem.

- **Client IP** — `CF-Connecting-IP` is the only real visitor IP; fly's `Fly-Client-IP` is a
  **Cloudflare PoP**, not the visitor. Code that needs the client reads `CF-Connecting-IP` first
  and falls back: `api/config/initializers/rack_attack.rb` and `web/src/log.ts` (the Worker). The
  header is spoofable by anything hitting an origin directly, so it may key throttling and
  logging but must **never** gate a ban.
- **Geo / trace headers** — `CF-IPCity` / `CF-Region` / `CF-IPCountry` for geo, `CF-Ray` as both
  the "this traversed the zone" marker and the join key into Cloudflare's logs.
- **Images** — Cloudflare Images serves every transformation from `<IMAGES_URL>/cdn-cgi/image/…`
  (PR #381), fetching the untransformed **source** from the R2 mirror rather than from Contentful
  (see **The image mirror** below). Details in [`web/CLAUDE.md`](web/CLAUDE.md).
- **OG cards** — **currently parked.** The on-demand `kona-og` service (which rendered `og:image`
  cards for cover-less pages) was removed from `main` and preserved on the `restore-og` branch; it
  isn't deployed. Cover-less pages ship no `og:image`; cover-image pages are unaffected. If revived,
  its card URL is content-addressed on the entry's `published_version` (year-long immutable cache,
  self-busting on republish) — one of the few things the zone should then cache hard (a Cache Rule /
  the `.png` extension), unlike the otherwise dynamic zone.
- **Caching** — the zone **edge-caches the static build**: HTML, feeds, and assets all come back
  `cf-cache-status: HIT` even with `max-age=0, must-revalidate` (the browser revalidates; the edge
  serves its own copy). Deploys do **not** self-invalidate at the edge — Cloudflare keeps serving
  the cached copy instead of revalidating against the freshly deployed asset — so invalidation is
  **explicit**: a **Cache Response Rule** tags every non-`/cdn-cgi/` response **on the site host**
  `Cache-Tag: site`, and `.github/workflows/web.yml` **purges tag `site` on every deploy** (see the
  zone-config note below). Image transformations (`/cdn-cgi/image/*`) are cached separately and
  never tagged, so the deploy purge leaves them intact. The **widget** fragments get their TTLs
  from the api's own `CDN-Cache-Control`, not from this rule — but the ones that render
  **Contentful** content are tagged `site` by a second branch of the same rule, scoped to the api
  host and to those paths, so a content publish (which dispatches a deploy, which purges the tag)
  evicts them instead of leaving them serving pre-edit content for an hour plus a day of
  `stale-while-revalidate`. The live-data widgets stay untagged (see below).
- **Bot blocking is a zone rule, not code** — the `block-bots` edge function that used to do this
  was **deleted** (`3c4e0044`). Its job — blocking a scraper that spoofs a Google referral (a
  desktop-Linux Chrome UA arriving with a `google.com` referer) — is now a **WAF BLOCK rule in
  the Cloudflare dashboard**. Don't reintroduce it as an edge function; if referral traffic
  looks wrong, read the rule before the code.
  ⚠️ The rule is **knowingly over-broad**: those conditions also match a real person on desktop
  Linux clicking a Google result, and blocking them is an accepted cost. The bot gets through
  managed, non-interactive **and** interactive challenges, so UA + referer is the only thing left
  that stops it. Don't "fix" the false positives by narrowing it to challenges — that's the
  approach that already failed. It's one of several custom rules — see **Zone security rules**
  below for the full set and the order they have to be in.
- **`/cdn-cgi/*` never reaches an origin** — Cloudflare answers it at its own edge, so edge
  functions don't need to exclude it. `source/robots.txt.erb` allows `/cdn-cgi/image/` and
  disallows the rest.

⚠️ **The Transformations source allowlist names the image-mirror host and nothing else. Never
add `*.ctfassets.net` to it.** Contentful's absence is deliberate and load-bearing: it's what
makes a bad or missing `IMAGE_HOST` fail *loudly*. Allowlist ctfassets and the same
misconfiguration instead renders a perfect-looking site straight off Contentful while draining
the metered asset bandwidth the mirror exists to protect — the same invisible regression the
`IMAGES_URL` fallback was deleted for. This is why `IMAGE_HOST` is a **required** var and not a
one-variable rollback (see **The image mirror** below).

Zone-side settings the code hard-depends on, none of them in the repo: **Transformations**
enabled with the image-mirror host allowlisted as a source (and only it, per the warning above);
the R2 bucket's **custom domain** and its **bot-protection skip**
(see **The image mirror** below); the
**Add visitor location headers** managed transform (without it `CF-IPCity`/`CF-Region` are
absent and geo logging degrades to country-only); the **Cache Response Rule** that sets
`Cache-Tag: site`, whose expression has **two host-scoped branches** — without it the deploy's tag
purge in `.github/workflows/web.yml` matches nothing and republished content stays stale at the
edge:

```
(http.host eq "<site host>" and not starts_with(http.request.uri.path, "/cdn-cgi/"))
or
(http.host eq "<api host>" and (
  starts_with(http.request.uri.path, "/widgets/articles/")
  or starts_with(http.request.uri.path, "/widgets/events/")
))
```

The **first** branch is the static build: every page, feed, and asset. The **second** is the widget
fragments that render **Contentful** content, matched by route namespace: `/widgets/articles/*`
(trending, trending-excluding, related) and `/widgets/events/*` (upcoming). The api origin host
lives in the same zone, and the fragments the web Worker's upstream fetch edge-caches are keyed on
*that* host (not the Worker's), so they're reachable by the same rule and the same purge. Contentful
publishes dispatch a deploy, so this is what keeps those widgets from serving pre-edit content for
their full edge TTL.

Matching by namespace rather than enumerating routes is deliberate, and it's not a loose
approximation: **articles and events are Contentful content types**, so anything served under those
two prefixes renders Contentful data by definition. A new widget in either namespace is therefore
tagged correctly and automatically, and the rule can't silently fall out of sync with
`api/config/routes.rb`.

⚠️ **Both the host scoping and the namespace scoping are load-bearing — never collapse this to a
path-only or host-only match, and never widen the second branch to `/widgets/`.** Purging a widget
drops its `stale-while-revalidate` / `stale-if-error` copies along with the fresh one, and those are
what keep widgets rendering through a fly outage; a blanket `/widgets/*` would put **every** widget
in the deploy purge, so a Contentful publish landing mid-outage would collapse all of them
site-wide. The trade is worth it only where there's stale content to fix: the live-data widgets
(`weather/current`, `activity-stats`, `whoop`, `plausible/pageviews/:id`) render nothing from
Contentful and sit in their own namespaces, which is what keeps them out. Everything else on the api
host — `/api/*`, `/webhooks/*` — stays out for the same reason.

⚠️ **A Contentful-backed widget added under a NEW top-level namespace needs this rule edited in the
dashboard**, and nothing in the repo will remind you — the widget will simply go stale forever,
silently. Routes added under `articles/` or `events/` are already covered.

⚠️ **The image-mirror host is deliberately absent from both branches, and must never be added.**
Its objects are immutable and content-addressed (replacing an asset's file mints a new Contentful
token, so the URL changes on its own), so there is nothing a purge could fix — while tagging them
would dump the entire image cache on every deploy, i.e. on every content publish, sending every
Cloudflare PoP back to R2 for images that hadn't changed.

⚠️ Both hostnames are typed by hand here and neither is validated: a rule with a misspelled host
saves cleanly, matches nothing, and fails **silently**. Paste them from the zone's DNS records, and
verify with Cloudflare Trace or by watching `cf-cache-status` on a widget URL across a deploy.

(Setting the tag via the web `_headers` `Cache-Tag` header does **not** work — Cloudflare doesn't
consume it, it just leaks the header to clients — so the tag must come from this rule, which is why
it's a hard zone dependency. The rule runs in the `http_response_cache_settings` phase, i.e. after
the origin response, and applies to Worker subrequests as well as eyeball requests — which is what
lets one rule cover both branches.) Plus the WAF rules below.

### Zone security rules

The zone is on Cloudflare **Pro**, which unlocks WAF **Managed Rules** and **Super Bot Fight
Mode**. Both apply **zone-wide, including to the api host** — and that's the trap: nearly all the
traffic on the api host is machine-to-machine and looks exactly like what those features exist to
block.

⚠️ **Order matters: the skip rule has to exist *before* the features are enabled**, or every
widget 403s site-wide the moment Super Bot Fight Mode goes on.

Custom rules, evaluated top to bottom. The BLOCK rules stay above the skip so they still fire
first — and the skip does **not** tick "All remaining custom rules", so it wouldn't shadow them
even if the order slipped:

| # | Rule | Expression | Action |
|---|---|---|---|
| 1 | Abusive Linux crawler with fake Google referrer | UA + `google.com` referer (see above) | Block |
| 2 | Block scanner noise | Path families no host in the zone serves: known-bad extensions, tool/framework prefixes, dot-segments, secret-material filenames, encoded dots, exotic methods (see below) | Block |
| 3 | Block access to original images | `http.host eq "<image host>" and not any(http.request.headers["via"][*] contains "image-resizing")` | Block (403) |
| 4 | Skip bot protection for public paths | `(http.host in {"<site host>" "<image host>"}) or (http.host eq "<api host>" and (starts_with(http.request.uri.path, "/api/") or starts_with(http.request.uri.path, "/widgets/") or starts_with(http.request.uri.path, "/webhooks/")))` | Skip → all managed rules **and** all Super Bot Fight Mode rules |

**Rule 2 — scanner noise.** One big `or` over `lower(http.request.uri.path)`, matching by *family*
rather than by observed URL: known-bad extensions (`.php`, `.env`, `.sql`, `.yml`, `.swp`, `.pem`,
`.key`, …), tool/framework prefixes (`/wp-`, `/cgi-bin/`, `/actuator/`, `/phpmyadmin/`, `/k8s/`,
`/terraform/`, `/secrets/`, `/config/`, `/deploy/`, `/flask/`, `/pki/`, `/home/`, `/analytics/`),
secret-material filenames with no extension to key off (`credential`, `cognito`, `/id_` — which
covers `id_rsa`/`id_dsa`/`id_ed25519`), any **dot-segment anywhere** (`contains "/."`, with
`/.well-known/` exempted — the one dotted path the site actually serves), and anything outside
`GET`/`HEAD`/`POST`.

⚠️ **Scanners percent-encode the dots** (`/terraform/%2eenv%2estaging`, `/connection%2ephp%2eswp`)
specifically to walk past extension matching, so the rule also blocks a bare `contains "%2e"`.
Whether it ever fires depends on the zone's **Normalize incoming URLs** setting (Rules → Settings),
which percent-decodes unreserved characters *before* rules evaluate; Security Events shows the raw
path either way, so **you cannot tell which form the rule saw from the dashboard**. Every clause
above is therefore chosen so each blocked family matches in *both* forms — don't drop the `%2e`
clause because it looks redundant, and don't drop a decoded-form clause because `%2e` "already
covers it". Nothing legitimate in the zone has an encoded dot: page URLs are extensionless ASCII
slugs, R2 keys carry literal dots, and `/cdn-cgi/image/…` embeds its source URL unencoded
(`web/lib/helpers/image_helpers.rb`).

⚠️ **The prefixes are anchored with `starts_with`, and the rule is zone-wide (it sits above the
skip).** Two things to keep in mind before adding to it: `activate :directory_indexes` means pages
are served at `/<slug>/`, so a top-level page slugged `config`, `home`, `analytics`, or `deploy`
would be blocked by its own prefix clause — check `data/pages.json` before adding a prefix, and
remember this if a new page ever 403s. And every clause has to stay false for the api host
(`/widgets/`, `/api/`, `/webhooks/`, `/whoop/`, `/auth/`, `/login`, `/sidekiq`, `/up`) and for the
R2 key shape (`{space}/{asset id}/{token}/{filename}`), not just for the site build.

**Rule 3 — direct access to the mirrored originals.** Cloudflare marks its own transformation
subrequests with `image-resizing` in the `Via` header, which is what lets this tell "Cloudflare
Images fetching a source" apart from "someone typing the URL in".

⚠️ **Never simplify this to a bare `http.host eq "<image host>"` block** — the transformation's
fetch of the source *does* traverse the rules pipeline (Cloudflare's own docs: "Transform Rules
run both before and after transformation requests"), so a blanket block 403s **every image on the
site**. After editing it, always verify **both** directions: a direct `curl` of an object must
403, *and* a page must still render its images.

⚠️ **It is friction, not a boundary, and both gaps are measured, not theoretical:**

- `Via` is an ordinary request header. `curl -H 'Via: 1.1 image-resizing' <object>` returns **200**.
- The transformation endpoint on the site host takes an arbitrary width, and Cloudflare will serve
  whatever the source supports: `/cdn-cgi/image/width=7728/<source>` returns a **3.0MB
  full-resolution** render. Rule 3 doesn't touch that path.

So it stops hotlinking, right-click-and-save, and untargeted crawlers — nothing more. The only
thing that would actually bound the maximum obtainable resolution is **capping the stored master**
(mirroring `?w=2560` instead of the original), since Cloudflare won't upscale past the source.

**Rule 4 — one consolidated skip.** This replaces three narrower skips (api host → SBFM,
`/webhooks/` → managed rules, image host → SBFM). What each branch is still carrying:

- **The site host** — SBFM was blocking **feed readers and Open Graph scrapers**. "Verified bots:
  Allow" covers Googlebot/Bingbot but not Slack/Mastodon/Discord unfurlers or RSS clients, and
  those are exactly the traffic a blog wants. Managed rules are skipped alongside it because the
  host serves a static build.
  ⚠️ Not *purely* static, though: `run_worker_first` claims `/widgets/*`, `/api/contact`, and
  `/pa/*`, and `POST /api/contact` is a real intake carrying arbitrary user prose. Managed rules
  were never the layer defending it — the honeypot, Turnstile, Akismet, the length caps, and the
  `contact/ip` throttle are (and OWASP is deliberately not deployed precisely because it would
  flag the form's own prose). Keep it that way; don't let this skip become the excuse to thin
  those out.
- **The image host** — the source fetch has no browser fingerprint at all, the textbook
  "definitely automated" verdict, so SBFM would collapse every image at once. The bucket serves
  nothing but immutable public image bytes.
- **The api host's machine namespaces** — `web/src/api-proxy.ts` builds the upstream widget
  request with **only** an `authorization` header: no `user-agent`, no `accept`, deliberately (the
  cache entry has to be byte-identical for every viewer — see the proxy notes below). No UA is the
  same "definitely automated" fingerprint, so SBFM would collapse every widget at once. `/api/`
  also covers the build-time callers (`GET /api/standard-site`, `POST /api/icons` from GitHub
  Actions) and `POST /api/build`. `/webhooks/` carries unattended POSTs of arbitrary Contentful
  rich text, which will trip a managed injection rule sooner or later; both are HMAC-verified, so
  managed rules add nothing. ⚠️ A block there fails **silently** — nothing surfaces an error, the
  standard.site PDS sync simply stops happening.
  The api loses little: every endpoint is bearer-gated and rack-attack throttles what gets past.
  If the host match ever needs narrowing, `cf.worker.upstream_zone` (empty on eyeball requests,
  the zone name on Worker subrequests) scopes it to proxy traffic specifically.

⚠️ **Rate limiting rules are deliberately NOT in the skip list** — the `/api/contact` limiter and
the site-host crawler brake still apply to everything above. Don't add them.

⚠️ **Both of these rules name hostnames typed by hand, and neither is validated.** A misspelled
host saves cleanly, shows as Active, and matches nothing — silently. That has already happened
once here (rule 3 shipped pointing at a nonexistent host and blocked nothing). Paste hostnames
from the zone's DNS records, then confirm the rule's **Events** counter is non-zero.

**Managed rules** — deploy the **Cloudflare Managed Ruleset** with the ruleset action overridden to
**Log**, read Security Events for a week, then switch to default actions. The **OWASP Core Ruleset**
is deliberately **not** deployed: it's high-noise, aimed at apps with real query surface, and the
main thing it would catch here is the contact form's own prose. If it's ever turned on: PL1, score
threshold High (60), action Log — never tighter.

**Super Bot Fight Mode** — definitely automated: Block; likely automated: Managed Challenge;
verified bots: Allow (keeps Googlebot/Bingbot); JS detections: on; **static resource protection:
off** (it would challenge the site's own CSS/JS/font requests). ⚠️ It does **not** replace custom
rule 1 — that scraper walks through interactive challenges, which is the whole reason that rule
blocks on UA + referer instead.

**Rate limiting rules** (Pro allows 2, and unlocks the challenge actions the Free plan didn't have):

- `/api/contact` — stays on **Block**. ⚠️ Never a challenge action: the no-JS native POST path
  can't solve one by definition, so challenging it would break the progressive-enhancement
  fallback the endpoint is built around.
- Site-host crawler brake — `http.host eq "<site host>" and http.request.method in {"GET" "HEAD"}
  and not starts_with(http.request.uri.path, "/cdn-cgi/")`, counted per IP, ~200 req/min →
  Managed Challenge. ⚠️ Don't tighten much below that: Pagefind fetches a burst of index chunks
  per search and Turbo prefetches on hover, so one real reader sits well above a naive
  page-views-per-minute rate.

**Cache Rules** — exactly one, and it is scoped far more narrowly than it looks like it needs to be.
Every clause below is load-bearing:

```
http.host eq "<site host>"
and not http.request.uri.path contains "."
and not starts_with(http.request.uri.path, "/cdn-cgi/")
and not starts_with(http.request.uri.path, "/widgets/")
and not starts_with(http.request.uri.path, "/api/")
and not starts_with(http.request.uri.path, "/pa/")
```

Eligible for cache; **Edge TTL: ignore cache-control, 1 day**; **Browser TTL: respect origin** (so
the browser keeps `max-age=0, must-revalidate` and picks up a deploy purge immediately).

What it's for: HTML never runs Worker code — `run_worker_first` in `web/wrangler.jsonc` is a
positive allowlist of three routes — so page views come from the **static asset layer**, which
Cloudflare already caches and tiers on its own. There is therefore no origin round trip, TLS
handshake, or cold start to absorb, and the rule buys nothing on a page that's already `HIT`
(`HIT` means the edge answered *without* contacting the origin; `REVALIDATED` is the one that
costs a round trip). The gain is **archive residency**: most URLs here are old posts getting a
handful of hits per PoP, so they fall out of a short edge TTL between visits and come back
`MISS`/`EXPIRED`. A long edge TTL keeps that long tail resident. ⚠️ Don't over-extend the TTL
chasing this — PoP caches evict under LRU regardless, so a month buys far less than 30× a day.

Why each exclusion:

- **`contains "."`** is what isolates HTML (the build's page URLs are extensionless). Without it the
  rule also matches `/javascripts/*` and `/stylesheets/*` — fingerprinted by `asset_hash` and set
  `immutable` in `source/headers` — plus `source/images` and `source/fonts`, which set no
  `Cache-Control` at all and ride Cloudflare's extension defaults. Browser TTL "respect origin"
  means nothing would go *stale*, but the **edge** would evict and re-fetch content-addressed
  assets daily for no benefit. It also keeps the feeds, `sitemap.xml`, `robots.txt`, `favicon.ico`,
  `manifest.json`, and the Pagefind chunks on their existing behavior.
- **`/widgets/`, `/api/`, `/pa/`** — ⚠️ the three Worker routes live on the **site** host and are
  extensionless, so they'd otherwise match. A 1-day edge TTL on `/widgets/*` at the Worker hostname
  would pin every widget for a day, overriding the `CDN-Cache-Control` design wholesale; caching
  `/pa/*` would corrupt analytics. **A new `run_worker_first` entry needs a matching exclusion
  here**, and nothing in the repo will remind you.
- **`/cdn-cgi/`** — belt and braces; Cloudflare answers it at its own edge anyway. Contentful images
  are unaffected either way: they're served from `<IMAGES_URL>/cdn-cgi/image/…`, which never reaches
  an origin.

⚠️ **Never add a cache rule on the api host.** Widget TTLs come from the origin's own
`CDN-Cache-Control` (`api/app/controllers/concerns/live_widget.rb`) and a cache rule would override
them wholesale.

The `Cache-Tag: site` Cache **Response** Rule runs in a different phase
(`http_response_cache_settings`), so tagging and the deploy purge are unaffected by any of this. That
purge is what makes the 1-day edge TTL safe: without it, a failed purge would mean stale content for
the full TTL rather than until the next revalidation.

Other zone settings, none load-bearing but all deliberate: **Smart Tiered Cache** on (fewer origin
hits means fewer cold starts on the scale-to-zero fly machine behind the widgets); **Page Shield**
script monitoring on (third-party script inventory, observational only); Early Hints, HTTP/3, 0-RTT,
Crawler Hints on. **Polish and Mirage stay off** — every image already goes through
`/cdn-cgi/image/*`, which picks format and quality; Polish only touches images served from origin,
and Mirage can degrade quality for no gain.

## How the two apps connect (request path)

The API's routes are split by namespace: `/widgets/*` returns HTML widget fragments (proxied,
below), `/api/*` accepts or returns structured data (`POST /api/location`,
`GET /api/standard-site`, `POST /api/icons`, `POST /api/build` — hit directly at `KONA_API_URL`,
not proxied; `POST /api/contact` is the exception — it's browser-reachable through the same
proxy, below),
and `/webhooks/*` receives inbound webhooks from external services (also hit directly, e.g. by
Contentful). The web build reads two of these at build time: `GET /api/standard-site` for the
verification markup, and `POST /api/icons` for its Font Awesome icons (the Font Awesome
integration lives only in the api — web posts its allowlist and gets back pre-rendered SVGs).

1. Browser requests `/widgets/*` (or `POST /api/contact`) on the main site.
2. The `kona-web` Worker (`web/wrangler.jsonc`) claims those paths — they're two of the three
   entries in its `run_worker_first` allowlist, so unlike ordinary page views they invoke Worker
   code rather than being served from the static asset layer.
3. `web/src/api-proxy.ts` proxies the request to `KONA_API_URL` (the fly.io origin, itself behind
   Cloudflare).
4. That upstream `fetch` is made cacheable (`cf: { cacheEverything: true }` — widget URLs are
   extensionless, so Cloudflare's extension-based default would cache nothing), and its TTL comes
   entirely from the origin's `CDN-Cache-Control` (RFC 9213 — see
   `api/app/controllers/concerns/live_widget.rb`). One cached copy is reused by all viewers. The
   contact POST opts out of the cache entirely. ⚠️ The entry is cached under the **api** hostname,
   not the Worker's — which is why the zone rule that tags the Contentful-backed widgets `site` is
   scoped to that host (see the caching notes above). The proxy itself does no tagging: it neither
   sets `cf.cacheTags` nor knows which widgets render Contentful content, and it shouldn't — that's
   a property of the data an endpoint renders, and duplicating the path list here would mean two
   places to keep in sync with `api/config/routes.rb`.

⚠️ The proxy claims `/api/contact` **explicitly, not `/api/*`** — the other `/api/*` endpoints
stay origin-only (build-time / server-side callers). Don't broaden it to `/api/*`, or you'd
expose `POST /api/location`, `POST /api/icons`, and `POST /api/build` (which ships a production
deploy) to the browser with the injected bearer.

The proxy is deliberately strict:

- Forwards only the `accept` **request** header and **injects** a constant
  `Authorization: Bearer <API_TOKEN>` (the client's own `authorization` is dropped). The
  token is the same for every viewer, so every upstream request stays identical → one shared
  cache entry. It authenticates to the origin (the API requires it on every widget endpoint and
  on `/api/contact`), so the origin is closed to the public; injecting it server-side keeps it
  out of the browser. ⚠️ `API_TOKEN` must be set in the Worker's dashboard secrets and
  **match the API's `API_TOKEN`** or every widget 401s and collapses site-wide.
- Passes the origin's `Cache-Control` through verbatim (what the browser sees).
- Does **not** forward `CDN-Cache-Control` downstream — it's consumed by the upstream fetch
  cache above, and the browser has no use for the edge policy.
- Keys the edge cache on **path only** — no query params, no per-user vary. Widget inputs are
  path segments, so entries are already isolated per widget.
- Returns an empty, briefly-cached `502` if the upstream fetch throws, so an origin blip
  collapses the widget (matching the origin's own "no data" signal) instead of being pinned.
- **Contact-only:** forwards the real visitor IP/UA/geo (`CF-Connecting-IP` → `X-Kona-Client-IP`,
  `user-agent` → `X-Kona-Client-UA`, `CF-IPCity`/`CF-Region`/`CF-IPCountry` →
  `X-Kona-Client-City`/`-Region`/`-Country`) — the origin can't see the visitor otherwise (the
  zone rewrites the `CF-*` headers to describe the Worker's egress/PoP, the same shared-egress trap
  that rules out IP throttling on `client_ip`). The API uses these for Akismet, the per-visitor
  rate-limit, and the notification email — **never** for a ban. It also forwards the `Location`
  header so the no-JS `303` → Thank-You redirect reaches the browser.

⚠️ Don't break these: keep widget inputs in the **path** (IDs are path segments, not
query strings), only emit durable edge headers on success responses, and keep the injected
`Authorization` constant (a per-request token would shatter the shared cache entry).

### Contact form (`POST /api/contact`)

The contact page's form (a web partial, `source/partials/_contact_form.html.erb` — **not** raw
HTML in the Contentful body, which SmartyPants would corrupt; the intro copy stays in Contentful)
posts to `/api/contact` through the proxy. `Api::ContactController` drops honeypot hits (the
hidden `comment` field) and
enqueues a `ContactMailJob`, which spam-checks with **Akismet** and emails the owner via
**Resend** (an HTTPS API — fly blocks outbound SMTP) with `Reply-To` set to the sender (the
reason this replaced the hosting provider's built-in form handling, which set the wrong
Reply-To). It's **progressively
enhanced**: the
`contact` Stimulus controller posts via `fetch` with `Accept: application/json` (→ `204`/`422`,
toast, no navigation); without JS the native POST sends `Accept: text/html` (→ `303` to the
Contentful Thank-You page at `/contact/success`). Same endpoint, same validation/honeypot/spam
path for both.

Defense layers: honeypot + Akismet (both paths), server-side length caps, a per-visitor
rack-attack throttle keyed on the forwarded `X-Kona-Client-IP` (`contact/ip`), and **Cloudflare
Turnstile**. ⚠️ Turnstile needs JS (single-use, 300s tokens), so it's verified server-side
(`Turnstile` siteverify) **only on the JSON path**; the no-JS path relies on the other layers.
Turnstile and Akismet both **fail open** when *unconfigured*. When Akismet *is* configured it
fails **closed** — an Akismet outage raises and retries the (delivery-split) intake job rather
than delivering a message that wasn't spam-checked. The email carries a "Sender details" block
(IP/geo/UA/time) from the forwarded headers.

## The image mirror (a cross-app contract with no code path between the apps)

Every image on the site is a Cloudflare Images transformation, and Cloudflare fetches the
untransformed **source** from whatever host the URL names. A source outside the zone can't use
Tiered Cache or Cache Reserve, so pointing it at Contentful meant every Cloudflare PoP
independently pulled the full-size original and re-pulled it on eviction — which is what drove
Contentful's asset bandwidth up, and why enabling Tiered Cache and Cache Reserve changed nothing.

So the assets are mirrored into a **Cloudflare R2 bucket** served from its own custom domain in
the zone, and that hostname is the transformation source. Production never touches Contentful for
images; only the mirror does, once per asset version.

The two apps meet **only through the shape of a URL** — there is no request between them, nothing
imports anything, and neither validates the other:

| | Who | What |
|---|---|---|
| Writes | `api` — `AssetMirror` + `AssetSyncJob`, on the Contentful **asset publish** webhook, plus `rake assets:backfill` | An R2 object keyed on Contentful's path **verbatim**: `{space}/{asset id}/{token}/{filename}` |
| Reads | `web` — `Contentful#rewrite_image_urls` at build time, gated on `IMAGE_HOST` | Swaps **only the host**, so the emitted path is that same key |

⚠️ Both sides match **every `*.ctfassets.net` host**, and must keep matching the same set.
Contentful is not split images-here / files-there: it serves plenty of ordinary image assets
from `downloads.ctfassets.net` (20 JPEGs in this space at the time of writing), and that host
doesn't support the Images API at all — which is also why `StandardSite#images_api_url` rewrites
the host before resizing. Narrowing either side to `images.ctfassets.net` leaves those assets
hitting Contentful forever, silently, which is the exact thing this exists to stop. Asset paths
are identical across the hosts, so one key covers an asset whichever host named it.

⚠️ **A mismatch — wrong bucket, wrong custom domain, a "tidied" key shape, `IMAGE_HOST` set before
the backfill finished — 404s every image on the site, and nothing anywhere reports it.** Both
sides must change together. The rollout order is: bucket + custom domain + the SBFM skip rule
(above) + the mirror host on the **Transformations source allowlist** → deploy the api with the
`R2_*` secrets → `rake assets:backfill` to completion → *only then* set `IMAGE_HOST` in the web
build env. Because the allowlist names only that host, the window between the last two steps is
the one where images are broken — so keep it short, and never "fix" it by allowlisting ctfassets.

Three consequences worth keeping straight:

- **The mirror is publish-only; unpublish and delete are ignored on purpose.** `web` reads
  Contentful with a **preview** token (`assetCollection(preview: true)`), so an unpublished asset
  is still in `data/assets.json` and still referenced by built pages — removing its object would
  break images that are live. Objects are immutable anyway, so nothing needs invalidating;
  orphans cost cents and are pruned by hand if it ever matters.
- **Blurhashes go through the mirror too.** `encode_blurhash` resizes its 32px thumbnail with
  `cdn_image_url` like every other image, so the source is the mirrored object and the resize
  lives in the URL **path**. It used to hit Contentful's Images API directly — deliberately, to
  avoid spending a transformation per asset — via a `:contentful_url` stash the rewrite kept and
  a `get_asset_contentful_url` helper. All three are gone: a transformation is a fraction of a
  cent against Contentful's metered bandwidth, and 20 of this space's assets are on
  `downloads.ctfassets.net`, which has no Images API at all, so those silently downloaded the
  full-size original on every cold build — the exact drain the mirror exists to stop.
  ⚠️ It must ask for an explicit `fm:` (it uses `jpg`). With no format Cloudflare returns the
  source format, and a libvips built without that loader fails the decode into
  `encode_blurhash`'s `rescue` — i.e. silently no placeholder, not a build error.
- **`IMAGE_HOST` is required — everywhere, including locally. It is not a rollback switch.**
  The rewrite still no-ops when it's blank, but there is no longer anywhere for those URLs to
  go: the zone's Transformations source allowlist names only the mirror host, so an unset
  `IMAGE_HOST` leaves every image pointed at `*.ctfassets.net` and **403s the lot**. That's
  deliberate — the alternative (allowlisting ctfassets so the unset case "works") is what would
  let a misconfigured build render perfectly while quietly billing Contentful's asset bandwidth.
  Rolling the mirror back means changing the allowlist in the dashboard first, not clearing one
  variable.
- **Direct access to the mirrored originals is blocked** by custom rule 3 (see **Zone security
  rules**), which allows only requests carrying `image-resizing` in the `Via` header — i.e.
  Cloudflare Images fetching a transformation source. ⚠️ It's hotlink protection, not a security
  boundary: the header is spoofable, and `/cdn-cgi/image/width=<source width>/` on the site host
  still renders at full resolution. The mirror stores **true originals** today (1.39GB, including
  a dozen 20–38MB camera JPEGs), so that's what a determined caller can still reach. Mirroring a
  capped master (`?w=2560`, measured at 21–49× smaller) is what would actually bound it.

## The cross-app HTML contract (most important)

The API returns HTML fragments that **replace** placeholder elements in the static
site, so their markup must stay structurally in sync across the two apps.

Mechanism — `web/source/javascripts/stimulus/controllers/live_update_controller.js`:
it reads `data-live-update-url-value`, fetches the fragment (on connect when
`data-live-update-fetch-on-connect-value="true"`, and again on tab `visibilitychange`),
and on a **non-empty** response replaces the entire placeholder element with the API
fragment. Consequences:

- The API fragment's **outermost element must itself carry** the
  `data-controller="live-update"` + `data-live-update-url-value` attributes, or it stops
  refreshing after the first swap.
- Its tag, CSS class names, and DOM shape must match the placeholder.
- An **empty** response (or any non-2xx / network error) makes the controller **remove the
  placeholder**, collapsing the widget rather than leaving a stuck loading skeleton. So an
  empty body is the intentional "no data" signal — don't "fix" it by returning markup.

On the web side, placeholders build the shared attribute cluster with the
`live_update_attrs` helper (`web/lib/helpers/site_helpers.rb`); the API views build the
matching outer element with `live_update_url`.

| Widget | web placeholder | api view | endpoint |
|---|---|---|---|
| Activity stats | `web/source/partials/placeholders/_stats.html.erb` | `api/app/views/widgets/activity_stats/show.html.erb` | `/widgets/activity-stats` |
| Whoop | `web/source/partials/placeholders/_whoop.html.erb` | `api/app/views/widgets/whoop/show.html.erb` | `/widgets/whoop` |
| Current weather | `web/source/partials/placeholders/_weather.html.erb` | `api/app/views/widgets/weather/current.html.erb` | `/widgets/weather/current` |
| Pageviews | `web/source/partials/article/_full.html.erb` (inline `span`) | `api/app/views/widgets/plausible/pageviews.html.erb` | `/widgets/plausible/pageviews/:id` |
| Upcoming races (race-day weather is inline in the featured event) | `web/source/partials/_upcoming_races.html.erb` | `api/app/views/widgets/events/upcoming.html.erb` | `/widgets/events/upcoming` |
| Trending articles | `web/source/partials/placeholders/_trending.html.erb` (the embedding page supplies the `url`: bare or `/:id` to exclude the current article) | `api/app/views/widgets/articles/trending.html.erb` | `/widgets/articles/trending` and `/widgets/articles/trending/:id` |
| Related articles ("You May Also Like") | `web/source/partials/placeholders/_related.html.erb` (the embedding page supplies the `url` with the article's Contentful id) | `api/app/views/widgets/articles/related.html.erb` | `/widgets/articles/related/:id` |

Shared CSS lives in `web/source/stylesheets/` (e.g. `stats`, `stats--has-four`,
`stats--has-three`, `weather`, `event__weather`).

⚠️ **When you change a widget's markup, class names, or DOM shape, edit the web
placeholder and the api view together** — and re-check the proxy constraints above.
