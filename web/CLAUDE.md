# web/ — Kona static site

Middleman 4 static site generator (Ruby 4.0.6) that builds a **Contentful**-powered
blog and deploys to the **`kona-web` Cloudflare Worker**, which serves the build as static
assets (images, client IPs, and bot blocking all depend on the zone — see the root
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
- **Contact form**: no longer the host's built-in form handling (the `__forms.html` decoy is
  gone). It posts to
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
# Ruby tests (Middleman helpers) — single file (fast) then full suite
bundle exec rspec spec/lib/helpers/markup_helpers_spec.rb
bundle exec rake test

# Worker tests (src/*.ts) — Vitest in the workers runtime (test/**), see below
npm test

# Local dev
bundle exec rake import          # fetch fresh data first
bundle exec middleman            # dev server (also runs the esbuild watcher — no separate terminal)

# Lint / format
npm run lint:scss                # stylelint (fix: npm run lint:scss:fix)
npm run format:check             # prettier for JS/JSON/MD (fix: npm run format)

# Full production build: test → import → middleman build (esbuild runs inside it)
bundle exec rake build:verbose

# Deploy control (the "Web" GitHub Actions workflow) — e.g. a content freeze during a bulk
# Contentful migration. Needs the gh CLI. Note the workflow's cancel-in-progress concurrency
# already collapses a publish storm into roughly one build, so this is rarely necessary.
gh workflow disable web.yml      # stop deploying (pushes and Contentful publishes won't build)
gh workflow enable web.yml       # resume
gh workflow run web.yml          # trigger one build now (from main)
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
- Open Graph "cards" (the `og:image` for pages without a cover image) were rendered **on demand**
  by a separate `kona-og` fly service. **That service is currently parked** (removed from `main`,
  preserved on the `restore-og` branch — it didn't earn its own app for now), so cover-less pages
  ship **no** `og:image`: `generate_open_graph_image_url` (`lib/helpers/image_helpers.rb`) returns
  `nil` when `OG_IMAGE_URL` is unset. Cover-image pages are unaffected (they use
  `open_graph_image_url` → Cloudflare Images). To revive: restore the service from `restore-og`,
  deploy it, and set `OG_IMAGE_URL` — the helper then builds
  `<OG_IMAGE_URL>/og.png?url=<page>&v=<template ver>-<published_version>` and no web code changes.
- `source/headers` / `source/redirects.erb` — built and renamed to `_headers` /
  `_redirects` (underscore-prefixed source files are treated as partials and skipped).
  ⚠️ In `_headers`, no two rules may set the same header for overlapping paths — matching
  rules comma-join same-name headers on Cloudflare.
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
  relative URLs are allowed", `code: 100324`). `redirects.erb` drops any absolute-URL-source rule
  from the generated file rather than letting a Contentful entry break the deploy. Cross-domain
  redirects must live in a Cloudflare **zone rule / Bulk Redirect**, not in `_redirects` or
  Contentful.
  ⚠️ **Cloudflare also rejects 200-status proxy rewrites to an absolute URL** ("Proxy (200)
  redirects can only point to relative paths", `code: 100324`). Nothing emits one today — the
  Plausible `/pa/*` first-party proxy that used to is now the Worker's job (`src/plausible.ts`) —
  but `redirects.erb` still drops any `status 200` + absolute-`to` rule, since redirects are
  authored in Contentful and a mis-entered one would otherwise fail the deploy with a bare error
  code. The analytics `<script>` snippet is unaffected (gated on `plausible_installed?`, i.e.
  `PLAUSIBLE_SCRIPT_URL` in the **build** env — separate from the Worker runtime var of the same
  name that powers the `/pa/*` proxy).
- `wrangler.jsonc` + `src/` — the Cloudflare Worker that **is** the site's hosting: it serves
  `build/` as static assets plus routes for the widget proxy, Plausible proxy, and contact form
  (`src/plausible.ts` does the `/pa/*` first-party proxying rather than `_redirects` rewrites).
  Typecheck the Worker with `npm run check` (`tsc --noEmit`; wrangler
  itself never typechecks), and **test it with `npm test`** — Vitest via
  `@cloudflare/vitest-pool-workers` runs `test/**` inside `workerd` (fake `env`, mocked outbound
  `fetch`), covering the proxy header/cache contract, the Plausible proxy, and routing. ⚠️ The test
  tooling is isolated from production types: `tsconfig.test.json`
  (test/** only, pulls in `@cloudflare/vitest-pool-workers` types) is **separate** from
  `tsconfig.json` (src only, `types: []` + the `env.d.ts` shims) — the two must never share a
  compile, or the workers-types `ExecutionContext` collides with the shim.
  ⚠️ **`run_worker_first` is a POSITIVE allowlist — only listed paths invoke the Worker.** It
  lists exactly the dynamic routes (`/widgets/*`, `/api/contact`, `/pa/*`); everything else — every
  HTML page, fingerprinted asset, the sitemap, the feeds, `/.well-known/*`, and any 404 — is served
  straight from the static asset layer and never runs Worker code (page views cost no Worker
  invocation). Each listed route needs the Worker because it has **no asset** (widgets/contact/pa
  would 404 at the asset layer) and must reach an origin. When you add a dynamic route, add its path
  here too, and mind that Cloudflare globs **cross `/`** (that's why `/widgets/*` matches nested
  paths like `/widgets/weather/current`). This replaced the old "`/*` minus ~25 asset negations"
  model — which kept tripping over extension negations (a blanket `!/*.js` once swallowed
  `/pa/script.js`, `!/*.xml` would have swallowed the feeds); the allowlist has no negations, so
  that class of bug is gone.
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
  `POST /api/icons` fetch; **must match the `api/` app's `API_TOKEN`**). Needed in TWO places:
  the build env (`.github/workflows/web.yml`) for the icons fetch, and the **Worker's dashboard
  secrets** — without the latter every widget 401s at the origin and collapses on the site.
- **Build credential**: `WEBAWESOME_NPM_TOKEN` — Web Awesome Pro npm registry auth, read
  by `.npmrc` at `npm install` (not in `.env`). Set it in your shell and in the workflow's
  build env, or the install fails.
- **Images — `IMAGES_URL`, required everywhere including locally**: the host Cloudflare Images
  serves transformations from (`<host>/cdn-cgi/image/…`), i.e. the site's public host. Building
  any image without it raises `ImageHelpers::ImagesUrlMissing`, so **it must be set in the build
  env** and in your local `.env` (point it at the real zone; `middleman server` then renders what
  production serves — auto avif/webp, cover images cropped to the OG size). It deliberately has **no fallback**: it
  used to resize via Contentful when unset, which looked perfect in the browser while draining
  Contentful's asset bandwidth, so the only thing the fallback reliably did was hide a broken
  deploy. Don't reintroduce one — `contentful_image_url` survives only for `encode_blurhash`,
  which uses it on purpose so blurhashes don't depend on the zone or spend a transformation.
  Cloudflare must also have Transformations enabled with `images.ctfassets.net` allowlisted as a
  source, or every image 403s.
- **Optional**: `TURNSTILE_SITE_KEY` (public Cloudflare Turnstile sitekey for the contact form —
  set it in the build env; pair with the api's `TURNSTILE_SECRET`, both or neither);
  `OG_IMAGE_URL` (base URL of the on-demand OG-card service — `generate_open_graph_image_url`
  builds the `og:image` card URL from it. **The `kona-og` service is currently parked** on the
  `restore-og` branch and not deployed, so this is normally unset: `generate_open_graph_image_url`
  then returns `nil` and cover-less pages simply omit `og:image` — cover-image pages are
  unaffected. Set it only if you revive `kona-og`).

## Conventions & gates

- **Before committing** (non-negotiable): `bundle exec rake test` + `npm test` (Worker suite) +
  `npm run check` (Worker tsc) pass → `npm run lint:scss` + `npm run format:check` clean →
  `bundle exec rake build:verbose` succeeds (it builds the JS bundle via the external pipeline).
  ⚠️ **`rake build` does NOT run tests** — building and testing are separate; run `rake test`
  yourself. The `.github/workflows/web.yml` `checks` job runs these same gates on every push/PR
  (it runs **`bundle exec rspec`** directly, not `rake test`: booting the Rakefile introspects the
  live Contentful schema (creds/network), whereas rspec loads only the specs — `contentful_spec`
  stubs that client — and runs credential-free), and it **gates the deploy** on code pushes.
  Follow `.editorconfig`.
- **`dependencies` vs `devDependencies`**: the CI deploy job installs with **`npm ci --omit=dev`**
  (it doesn't need the test/lint toolchain), so anything the **build or deploy** needs must be a
  `dependency`, not a `devDependency`: `esbuild` + the JS-bundle imports (`@hotwired/*`,
  `@web.awesome.me/*`), `pagefind`, and `wrangler`. Test/lint tools (`vitest`,
  `@cloudflare/vitest-pool-workers`, `typescript`, `stylelint*`, `prettier`) stay `devDependencies`
  — the `checks` job installs those with a full `npm ci`.
- **Tests** live in `spec/` and focus on helpers, text/markdown processing, and data
  transformation.
- **Widget markup**: editing a placeholder partial means editing the matching `api/`
  view too (root `CLAUDE.md`).

### Permissions

- Autonomous: read files, single-file `rspec`, lint/format, local `middleman`.
- Ask first: `git push`/commit, `rake redis:clear`, package installs, anything that
  triggers a deploy or build hook.
