# Kona — monorepo guide

This file covers the **monorepo shape and the contract between the two apps**. For
app-specific commands and conventions, read the nearest `CLAUDE.md`:

- [`web/CLAUDE.md`](web/CLAUDE.md) — Middleman static site (the blog).
- [`api/CLAUDE.md`](api/CLAUDE.md) — Rails API serving dynamic widgets.
- [`contentful/CLAUDE.md`](contentful/CLAUDE.md) — one-off Contentful content migrations.

Work on one app from inside its own directory; each has its own `Gemfile`,
`.env.example`, and test suite.

## Repo layout

| Path | What | Deploy |
|---|---|---|
| `web/` | Middleman 4 static site generator (Ruby 4.0.6). Builds the Contentful-powered blog and serves all static pages. | Netlify (behind Cloudflare) |
| `api/` | Rails 8.1 API (Ruby 4.0.6). Serves small dynamic HTML fragments ("widgets") embedded into the static pages at runtime, plus a Sidekiq `worker` process for background jobs (standard.site PDS sync). | fly.io (`kona-api`: `app` + `worker`) — behind Cloudflare |
| `redis/` | Config (`fly.toml`) for the `kona-redis` fly app — the API's dedicated Redis (cache + Sidekiq queues). | fly.io (`kona-redis`) |
| `contentful/` | One-off Contentful content migrations (Node scripts, run locally). Deliberately outside `web/` so edits don't trigger Netlify builds. | — (never deployed) |
| `netlify.toml` (root) | Drives the Netlify build: `base = "web"`, `command = "bundle exec rake build"`, `publish = "build/"`. | — |

Each app has its own Redis, configured via its own `REDIS_URL`: `api/` uses the dedicated
`kona-redis` fly app (`redis/fly.toml`); `web/` uses a separate Upstash instance. The apps
keep distinct keyspaces, so there's no cross-app data sharing to preserve.

One-off **Contentful content migrations** (scripts that rewrite the content itself) live
in `contentful/` — see [`contentful/CLAUDE.md`](contentful/CLAUDE.md) for the conventions
(dry runs, skip-unchanged, inverses, rollout ordering).

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

⚠️ **Both origins are proxied through Cloudflare** (orange-cloud DNS): the public site
(→ Netlify) and the api/admin host (→ fly.io). **Nothing in this repo configures the zone** —
it's all dashboard-side, so it's invisible to `grep` and easy to miss. Assume every production
request traverses Cloudflare before it reaches Netlify or fly, and check the zone before
concluding something is a code problem.

- **Client IP** — `CF-Connecting-IP` is the only real visitor IP. Netlify's `context.ip` and
  fly's `Fly-Client-IP` are both **Cloudflare PoPs**, not the visitor. Code that needs the
  client reads `CF-Connecting-IP` first and falls back: `api/config/initializers/rack_attack.rb`,
  `web/src/log.ts` (the Worker), and `web/netlify/functions/lib/log.mts` (the legacy Node function,
  pending removal). The header is spoofable by anything hitting an origin directly, so it may key
  throttling and logging but must **never** gate a ban.
- **Geo / trace headers** — `CF-IPCity` / `CF-Region` / `CF-IPCountry` for geo, `CF-Ray` as both
  the "this traversed the zone" marker and the join key into Cloudflare's logs.
- **Images** — Cloudflare Images serves every transformation from `<IMAGES_URL>/cdn-cgi/image/…`
  (replaced the Netlify Image CDN in PR #381). Details in [`web/CLAUDE.md`](web/CLAUDE.md).
- **OG cards** — **currently parked.** The on-demand `kona-og` service (which rendered `og:image`
  cards for cover-less pages) was removed from `main` and preserved on the `restore-og` branch; it
  isn't deployed. Cover-less pages ship no `og:image`; cover-image pages are unaffected. If revived,
  its card URL is content-addressed on the entry's `published_version` (year-long immutable cache,
  self-busting on republish) — one of the few things the zone should then cache hard (a Cache Rule /
  the `.png` extension), unlike the otherwise dynamic zone.
- **Caching** — the zone is deliberately **dynamic: Cloudflare caches almost nothing**. The
  origin cache headers (Netlify's durable edge, the widget TTLs) still do the real work, so
  don't reason about widget caching as if Cloudflare were in the loop.
- **Bot blocking is a zone rule, not code** — the `block-bots` Netlify edge function was
  **deleted** (`3c4e0044`). Its job — blocking a scraper that spoofs a Google referral (a
  desktop-Linux Chrome UA arriving with a `google.com` referer) — is now a **WAF BLOCK rule in
  the Cloudflare dashboard**. Don't reintroduce it as an edge function; if referral traffic
  looks wrong, read the rule before the code.
  ⚠️ The rule is **knowingly over-broad**: those conditions also match a real person on desktop
  Linux clicking a Google result, and blocking them is an accepted cost. The bot gets through
  managed, non-interactive **and** interactive challenges, so UA + referer is the only thing left
  that stops it. Don't "fix" the false positives by narrowing it to challenges — that's the
  approach that already failed.
- **`/cdn-cgi/*` never reaches an origin** — Cloudflare answers it at its own edge, so edge
  functions don't need to exclude it. `source/robots.txt.erb` allows `/cdn-cgi/image/` and
  disallows the rest.

Zone-side settings the code hard-depends on, none of them in the repo: **Transformations**
enabled with `images.ctfassets.net` allowlisted as a source (without it every image 403s); the
**Add visitor location headers** managed transform (without it `CF-IPCity`/`CF-Region` are
absent and geo logging degrades to country-only); and the bot WAF rule above.

## How the two apps connect (request path)

The API's routes are split by namespace: `/widgets/*` returns HTML widget fragments (proxied,
below), `/api/*` accepts or returns structured data (`POST /api/location`,
`GET /api/standard-site`, `POST /api/icons` — hit directly at `KONA_API_URL`, not proxied;
`POST /api/contact` is the exception — it's browser-reachable through the same proxy, below),
and `/webhooks/*` receives inbound webhooks from external services (also hit directly, e.g. by
Contentful). The web build reads two of these at build time: `GET /api/standard-site` for the
verification markup, and `POST /api/icons` for its Font Awesome icons (the Font Awesome
integration lives only in the api — web posts its allowlist and gets back pre-rendered SVGs).

1. Browser requests `/widgets/*` (or `POST /api/contact`) on the main site.
2. **Cloudflare** proxies it through to Netlify (the zone caches almost nothing — see above).
3. The Netlify Function `web/netlify/functions/api-proxy.mts` claims those paths
   (`config.path = ['/widgets/*', '/api/contact']`) and proxies to `KONA_API_URL` (the fly.io
   origin, itself behind Cloudflare).
4. The response is cached at Netlify's edge and reused by all viewers (widget GETs only; the
   contact POST is never edge-cached).

⚠️ **Migration in progress (dual-deploy).** The same contract is served two ways at once: the
Netlify Function above, and — on the Cloudflare side — the `web/src/api-proxy.ts` route of the
`kona-web` Worker (`web/wrangler.jsonc`), which serves the static build and claims the same
paths. Both inject the identical bearer and key the edge cache on path only, so this section
holds for either host. The api emits its edge-cache policy in **both** dialects
(`Netlify-CDN-Cache-Control` with the `durable` token, and standard `CDN-Cache-Control` per
RFC 9213 that Cloudflare honors — see `api/app/controllers/concerns/live_widget.rb`). The live
site is still Netlify; the Worker runs in parallel until the DNS cutover. See `web/CLAUDE.md`.

⚠️ The proxy claims `/api/contact` **explicitly, not `/api/*`** — the other `/api/*` endpoints
stay origin-only (build-time / server-side callers). Don't broaden it to `/api/*`, or you'd
expose `POST /api/location` and `POST /api/icons` to the browser with the injected bearer.

The proxy is deliberately strict:

- Forwards only the `accept` **request** header and **injects** a constant
  `Authorization: Bearer <API_TOKEN>` (the client's own `authorization` is dropped). The
  token is the same for every viewer, so every upstream request stays identical → one shared
  cache entry. It authenticates to the origin (the API requires it on every widget endpoint and
  on `/api/contact`), so the origin is closed to the public; injecting it server-side keeps it
  out of the browser. ⚠️ `API_TOKEN` must be set in Netlify's env and **match the API's
  `API_TOKEN`** or every widget 401s and collapses site-wide.
- Passes the origin's `Cache-Control` through verbatim (what the browser sees).
- Forwards `Netlify-CDN-Cache-Control` (the durable edge policy) **only on 2xx**, so
  errors/redirects are never durably pinned at the edge.
- Keys the edge cache on **path only** — no query params, no per-user vary.
- **Contact-only:** forwards the real visitor IP/UA/geo (`CF-Connecting-IP` → `X-Kona-Client-IP`,
  `user-agent` → `X-Kona-Client-UA`, `CF-IPCity`/`CF-Region`/`CF-IPCountry` →
  `X-Kona-Client-City`/`-Region`/`-Country`) — the origin can't see the visitor otherwise (the
  zone rewrites the `CF-*` headers to describe the Netlify egress/PoP, the same shared-egress trap
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
reason this replaced Netlify Forms — Netlify set the wrong Reply-To). It's **progressively
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
