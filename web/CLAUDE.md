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
- `netlify/edge-functions/` — `known-agents.ts` (records every page view server-side to
  Known Agents / Dark Visitors, capturing bot + AI-agent traffic Plausible can't see;
  production-only, reuses `DARK_VISITORS_ACCESS_TOKEN`); `feed-source.ts` (per-reader feed URL
  attribution — its `Cache-Control: private` is load-bearing because Cloudflare ignores
  `Vary: User-Agent`). Both read the real client IP/geo from `CF-*` headers rather than
  `context.ip`/`context.geo`, via the shared `edge-functions/lib/log.ts` — a separate Deno copy
  of `functions/lib/log.mts` (edge functions run in Deno and can't import the Node module), shared
  between the two edge functions rather than re-inlined in each. There is **no** `block-bots`
  function any more — that moved to a Cloudflare WAF rule (root [`CLAUDE.md`](../CLAUDE.md)).
- Open Graph "cards" (the `og:image` for pages without a cover image) are rendered **on
  demand** by the separate `kona-og` fly service (repo-root `og/`), not at build time.
  `generate_open_graph_image_url` (`lib/helpers/image_helpers.rb`) builds the card URL at
  `<OG_IMAGE_URL>/og.png?url=<page>&v=<template ver>-<published_version>`; the service
  fetches the page, reads its `og:title`, and renders. See [`og/CLAUDE.md`](../og/CLAUDE.md).
- `source/headers` / `source/redirects.erb` — built and renamed to `_headers` /
  `_redirects` (underscore-prefixed source files are treated as partials and skipped).
  ⚠️ In `_headers`, no two rules may set the same header for overlapping paths — matching
  rules comma-join same-name headers on both Netlify and Cloudflare.
- `wrangler.jsonc` + `src/` — the Cloudflare Worker for the Netlify→Cloudflare migration:
  serves `build/` as static assets plus routes for the widget proxy, Plausible proxy, contact
  form, and Known Agents tracking. Its `src/*.ts` files are 1:1 ports of the `netlify/`
  functions/edge-functions above (each file header names its counterpart); `src/plausible.ts`
  additionally absorbs the `/pa/*` proxying Netlify does via `_redirects` rewrites.
  ⚠️ **Dual-deploy window**: both paths ship at once. The live site still runs on Netlify;
  the Worker deploys in parallel to Cloudflare (via Workers Builds — the reason `rake build`
  uses libvips) so it can be exercised on a preview host before the DNS cutover. Keep the
  `netlify/` and `src/` copies in sync until Netlify is retired. The two record Known Agents
  visits under different token names — Netlify reads `DARK_VISITORS_ACCESS_TOKEN`, the Worker
  reads `KNOWN_AGENTS_ACCESS_TOKEN` (same value) — and gate to production differently (Netlify
  by deploy context, the Worker by `SITE_HOSTNAME`). Typecheck the Worker with `npm run check`
  (`tsc --noEmit`; wrangler itself never typechecks). See the migration plan before touching
  the cutover pieces.
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
- **Optional**: `DARK_VISITORS_ACCESS_TOKEN`; `TURNSTILE_SITE_KEY` (public Cloudflare Turnstile
  sitekey for the contact form — set it in Netlify's build env; pair with the api's
  `TURNSTILE_SECRET`, both or neither).

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
