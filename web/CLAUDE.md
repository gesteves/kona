# web/ — Kona static site

Middleman 4 static site generator (Ruby 4.0.6) that builds a **Contentful**-powered
blog and deploys to **Netlify**, which is itself proxied behind **Cloudflare** (images,
client IPs, and bot blocking all depend on the zone — see the root
[`CLAUDE.md`](../CLAUDE.md)). esbuild bundles JavaScript (Stimulus + Turbo) and the
**Web Awesome** (Pro) component theme CSS via Middleman's external pipeline (`config.rb`):
Middleman runs esbuild itself, into the gitignored `tmp/dist/`, during both `middleman build`
(one-shot) and the dev server (watch mode) — there's no separate JS build step. Sass compiles
the rest of the stylesheets. UI components (toasts, form controls, skeletons, relative time,
scroller) come from Web Awesome Pro, imported in `source/javascripts/stimulus/index.js`.

This app no longer fetches its own weather / activity / Whoop data — that moved to the
`api/` app and is loaded at runtime. See the root [`CLAUDE.md`](../CLAUDE.md) for the
web↔api contract before touching any widget markup.

## Architecture & data flow

- **Build-time data** (`rake import`): fetches external data into `data/*.json` (Redis
  is used as a cache for Contentful content). Sources: Contentful content; Font Awesome
  icons (posted from the allowlist to the `api/` `/api/icons` endpoint, which resolves and
  caches them — web no longer talks to Font Awesome directly); and the standard.site
  verification data (DID + publication URI fetched from the `api/` `/api/standard-site`
  endpoint — the actual AT Protocol / Bluesky PDS publishing now lives in `api/`,
  webhook-driven).
  (robots.txt is a static Middleman template, `source/robots.txt.erb`, built here.)
- **Page generation**: Middleman proxies (`config.rb`) turn `data/*.json` into static
  pages — articles, pages, tags, blog index.
- **Runtime dynamic content**: weather, activity stats, Whoop, per-article pageviews,
  and event weather are **not built here**. The `live-update` Stimulus controller
  fetches them client-side from `/widgets/*` into placeholder partials (root `CLAUDE.md`).
- **Contact form**: no longer Netlify Forms (the `__forms.html` decoy is gone). It posts to
  `POST /api/contact` through the api proxy (`api/` sends the email via Resend with the correct
  Reply-To). It's progressively enhanced — the `contact` Stimulus controller (`sendNotification`
  toast, no navigation) over a real form that still works without JS (native POST → 303 to the
  Contentful `/contact/success` page).
  ⚠️ The `<form>` markup is a **partial** (`source/partials/_contact_form.html.erb`), rendered
  for the contact page in `partials/article/_body.html.erb` (`article.slug == 'contact'`) — **not**
  raw HTML in the Contentful body. It can't live in the body: `render_body` runs the body through
  Redcarpet **SmartyPants** (`lib/helpers/markdown_helpers.rb`), which curls the straight quotes
  in raw HTML *attributes* and corrupts the field names + Stimulus wiring. The intro copy above
  the form stays editable in Contentful; only the form markup is in the partial. Keep the field
  names (`name`, `email`, `message`, honeypot `comment`) in sync with the api (root `CLAUDE.md`).
  When `TURNSTILE_SITE_KEY` is set, the `contact` controller renders a **Cloudflare Turnstile**
  widget (explicit render, so it survives Turbo navigation) and sends its token with the `fetch`;
  the api verifies it server-side. No key → no widget, and the api's check fails open.

## Commands

Run `nvm use` before any `npm` command. Native dependency: **libvips** (`brew install
vips`) — the blurhash placeholders render through the `ruby-vips` gem (chosen over
ImageMagick because Cloudflare Workers Builds preinstalls libvips but not ImageMagick).

```bash
# Tests — single file (fast) then full suite
bundle exec rspec spec/lib/helpers/markup_helpers_spec.rb
bundle exec rake test

# Local dev
bundle exec rake import          # fetch fresh data first
bundle exec middleman            # dev server (also runs the esbuild watcher — no separate terminal)

# Lint / format
npm run lint:scss                # stylelint (fix: npm run lint:scss:fix)
npm run format:check             # prettier for JS/JSON/MD (fix: npm run format)

# Full production build: test → import → middleman build (esbuild runs inside it)
bundle exec rake build:verbose

# Netlify build control (scripts/netlify-builds.js) — e.g. a content freeze; needs
# NETLIFY_AUTH_TOKEN + NETLIFY_SITE_ID in .env. activate does NOT deploy; use deploy for that.
npm run build:status             # is the site's builds stopped or active?
npm run build:stop               # stop all Netlify builds (pushes/webhooks/hooks won't deploy)
npm run build:activate           # re-activate builds
npm run build:deploy             # trigger one production build now
```

### Import subtasks

Only these exist: `rake import` (runs all in parallel), `import:content` (Contentful),
`import:icons` (POSTs the `data/font_awesome.yml` allowlist to the `api/` `/api/icons`
endpoint in batches and writes `data/icons.json`), `import:standard_site` (fetches the
standard.site DID + publication URI from the `api/` `/api/standard-site` endpoint). Also
`rake redis:clear` to flush the cache. Unlike `import:standard_site` (which degrades
gracefully), a failed `import:icons` raises — icons are an every-page dependency, so the
build fails loudly rather than shipping pages with missing icons.

## Key locations

- `config.rb` — Middleman config + proxy setup; `Rakefile` — Redis init + task loader.
- `lib/data/*.rb` — build-time clients: `contentful.rb` (+ `graphql/`). (Icons are fetched
  from the `api/` `/api/icons` endpoint by `import:icons` in `lib/tasks/import.rake`, not a
  `lib/data` client.)
- `lib/tasks/*.rake` — `import`, `build`, `test`, `maps`, `redis`.
- `lib/helpers/*.rb` — helper modules (article, markup, image, site, share, icon,
  url, text, markdown, context, cache, affiliate_links, standard_site);
  `config.rb` requires and registers every module in that directory.
- `source/layouts/layout.erb`, `source/partials/` (incl. `placeholders/`),
  `source/javascripts/stimulus/`, `source/stylesheets/`.
- `netlify/functions/` — `api-proxy.mts` (proxies `/widgets/*` **and** `POST /api/contact`;
  see root `CLAUDE.md`).
- `netlify/edge-functions/` — `feed-source.ts` (per-reader feed URL attribution — its
  `Cache-Control: private` is load-bearing because Cloudflare ignores `Vary: User-Agent`). It
  reads the real client IP/geo from `CF-*` headers rather than `context.ip`/`context.geo`, via
  `edge-functions/lib/log.ts` — a separate Deno copy of `functions/lib/log.mts` (edge functions
  run in Deno and can't import the Node module). There is **no** `block-bots` function any more
  (moved to a Cloudflare WAF rule, root [`CLAUDE.md`](../CLAUDE.md)), and no `known-agents.ts` any
  more — server-side Known Agents / Dark Visitors tracking was removed; Cloudflare's own bot/AI
  analytics covers it.
- Open Graph "cards" (the `og:image` for pages without a cover image) are rendered **on
  demand** by the separate `kona-og` fly service (repo-root `og/`), not at build time.
  `generate_open_graph_image_url` (`lib/helpers/image_helpers.rb`) builds the card URL at
  `<OG_IMAGE_URL>/og.png?url=<page>&v=<template ver>-<published_version>`; the service
  fetches the page, reads its `og:title`, and renders. See [`og/CLAUDE.md`](../og/CLAUDE.md).
- `source/headers` / `source/redirects.erb` — built and renamed to `_headers` /
  `_redirects` (underscore-prefixed source files are treated as partials and skipped).
  ⚠️ In `_headers`, no two rules may set the same header for overlapping paths — matching
  rules comma-join same-name headers on both Netlify and Cloudflare.
  ⚠️ **`_redirects` rule ORDER is load-bearing on Cloudflare.** CF's parser counts 2,000
  "static" rules but only 100 "dynamic" ones, and its `canCreateStaticRule` flag **latches
  off at the first rule whose source has a splat (`*`) or `:placeholder`** — every rule after
  that, *even exact-match ones*, is counted as dynamic. So `redirects.erb` gathers all rules
  and emits every exact-match (static) redirect **before** any splat/placeholder (dynamic)
  one. Emit a splat rule early and the exact redirects below it get miscounted against the
  100-limit and the deploy fails (`code: 100324`) once the file passes ~100 lines. Keep the
  partition; don't hand-place a `*`/`:name` rule above the static block.
  ⚠️ **Cloudflare also rejects absolute-URL *sources*.** A rule whose `from` is a full URL (a
  cross-domain redirect, e.g. an old domain → this site) hard-fails the Worker deploy ("Only
  relative URLs are allowed", `code: 100324`) — Netlify allowed these, the Worker does not.
  `redirects.erb` drops any absolute-URL-source rule from the generated file (which also removes
  it from the Netlify build during dual-deploy). Cross-domain redirects must live in a Cloudflare
  **zone rule / Bulk Redirect**, not in `_redirects` or Contentful.
  ⚠️ **Cloudflare also rejects 200-status proxy rewrites to an absolute URL** ("Proxy (200)
  redirects can only point to relative paths", `code: 100324`). This is how Netlify does the
  Plausible `/pa/*` first-party proxy (`plausible_proxy_redirects` → `/pa/script.js` rewritten to
  `plausible.io`), but on Cloudflare that proxying is the Worker's job (`src/plausible.ts`), so
  those lines are invalid *and* redundant. `redirects.erb` drops any `status 200` + absolute-`to`
  rule. The analytics `<script>` snippet is unaffected (gated on `plausible_installed?`, i.e.
  `PLAUSIBLE_SCRIPT_URL` in the **build** env — separate from the Worker runtime var of the same
  name that powers the `/pa/*` proxy). Rolling back to Netlify would lose the `/pa/*` proxy until
  Netlify is retired.
- `wrangler.jsonc` + `src/` — the Cloudflare Worker for the Netlify→Cloudflare migration:
  serves `build/` as static assets plus routes for the widget proxy, Plausible proxy, and contact
  form. Its `src/*.ts` files are 1:1 ports of the `netlify/` functions/edge-functions above (each
  file header names its counterpart); `src/plausible.ts` additionally absorbs the `/pa/*` proxying
  Netlify does via `_redirects` rewrites.
  ⚠️ **Dual-deploy window**: both paths still ship. `www` has been cut over to the Cloudflare
  Worker; Netlify remains as a rollback until it's retired, so keep the `netlify/` and `src/`
  copies in sync until then. (Server-side Known Agents tracking that used to live in both — the
  Worker's `known-agents.ts` and the Netlify edge function — was removed; Cloudflare's own bot/AI
  analytics replaces it.) Typecheck the Worker with `npm run check` (`tsc --noEmit`; wrangler
  itself never typechecks). See the migration plan before touching the cutover pieces.
  ⚠️ **`run_worker_first` extension negations must never collide with a Worker route.** The
  `assets.run_worker_first` globs in `wrangler.jsonc` decide what skips the Worker and is served
  straight from the asset layer. Cloudflare globs **match across `/`**, and a **negative can't be
  overridden by a positive** — so a blanket `!/*.<ext>` silently excludes *any* Worker route that
  ends in that extension. This bit `/pa/script.js` (the Plausible proxy route): a `!/*.js` negation
  routed it to the asset layer → 404, never reaching `src/plausible.ts`. Scope asset exclusions by
  **directory** (`!/javascripts/*`, `!/stylesheets/*`) where the real assets live, not by a
  catch-all extension; if a root-level asset needs excluding, name it (`!/sitemap.xml`, not
  `!/*.xml` — which would also swallow the per-reader `/feed.xml` Worker route). Worker routes to
  keep clear of extension negations: `/pa/script.js`, `/feed.xml` (and `<tag>/feed.xml`).
- `data/font_awesome.yml` — **icon allowlist**. Any new icon must be added here (under
  the correct family/style, e.g. `classic.light`) before `icon_svg` / `rake import:icons`
  can use it. `import:icons` posts this tree to the `api/` `/api/icons` endpoint, which
  resolves each id on demand — so adding an icon is a pure web-side yml edit; no api change
  or redeploy is needed. The Font Awesome version lives in the api, not here.

## Environment variables

Names only — see `.env.example`; never commit values.

- **Required**: `CONTENTFUL_SPACE`, `CONTENTFUL_TOKEN`,
  `REDIS_URL`, `KONA_API_URL` (base URL of the `api/` app — used by the `/widgets/*` proxy
  and the build-time `import:icons` / `import:standard_site` fetches), `API_TOKEN` (shared
  bearer the `/widgets/*` proxy injects on every upstream request, and the build sends on the
  `POST /api/icons` fetch; **must match the `api/` app's `API_TOKEN`**, and must be set in
  Netlify's runtime env or every widget 401s at the origin and collapses on the site),
  `OG_IMAGE_URL` (base URL of the `og/` app — `generate_open_graph_image_url` builds the
  `og:image` card URL from it; a card without it raises).
- **Build credential**: `WEBAWESOME_NPM_TOKEN` — Web Awesome Pro npm registry auth, read
  by `.npmrc` at `npm install` (not in `.env`). Set it in your shell and in Netlify's
  build env, or the install fails.
- **Images — `IMAGES_URL`, required everywhere including locally**: the host Cloudflare Images
  serves transformations from (`<host>/cdn-cgi/image/…`), i.e. the site's public host. Building
  any image without it raises `ImageHelpers::ImagesUrlMissing`, so **it must be set in Netlify's
  env** and in your local `.env` (point it at the real zone; `middleman server` then renders what
  production serves — auto avif/webp, cover images cropped to the OG size). It deliberately has **no fallback**: it
  used to resize via Contentful when unset, which looked perfect in the browser while draining
  Contentful's asset bandwidth, so the only thing the fallback reliably did was hide a broken
  deploy. Don't reintroduce one — `contentful_image_url` survives only for `encode_blurhash`,
  which uses it on purpose so blurhashes don't depend on the zone or spend a transformation.
  Cloudflare must also have Transformations enabled with `images.ctfassets.net` allowlisted as a
  source, or every image 403s.
- **Optional**: `TURNSTILE_SITE_KEY` (public Cloudflare Turnstile sitekey for the contact form —
  set it in the build env; pair with the api's `TURNSTILE_SECRET`, both or neither).

## Conventions & gates

- **Before committing** (non-negotiable): `bundle exec rake test` passes →
  `npm run lint:scss` + `npm run format:check` clean → `bundle exec rake build:verbose`
  succeeds (it builds the JS bundle via the external pipeline). Follow `.editorconfig`.
- **Netlify**: build tools must be in `dependencies`, not `devDependencies` — Netlify
  installs with `NODE_ENV=production` and skips `devDependencies`.
- **Tests** live in `spec/` and focus on helpers, text/markdown processing, and data
  transformation.
- **Widget markup**: editing a placeholder partial means editing the matching `api/`
  view too (root `CLAUDE.md`).

### Permissions

- Autonomous: read files, single-file `rspec`, lint/format, local `middleman`.
- Ask first: `git push`/commit, `rake redis:clear`, package installs, anything that
  triggers a deploy or build hook.
