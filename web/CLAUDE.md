# web/ — Kona static site

Middleman 4 static site generator (Ruby 4.0.5) that builds a **Contentful**-powered
blog and deploys to **Netlify**. esbuild bundles JavaScript (Stimulus + Turbo) and the
**Web Awesome** (Pro) component theme CSS; Sass compiles the rest of the stylesheets.
UI components (toasts, form controls, skeletons, relative time, scroller) come from
Web Awesome Pro, imported in `source/javascripts/stimulus/index.js`.

This app no longer fetches its own weather / activity / Whoop data — that moved to the
`api/` app and is loaded at runtime. See the root [`CLAUDE.md`](../CLAUDE.md) for the
web↔api contract before touching any widget markup.

## Architecture & data flow

- **Build-time data** (`rake import`): fetches external data into `data/*.json` (Redis
  is used as a cache). Sources: Contentful content, Font Awesome icons, and the
  standard.site verification data (DID + publication URI fetched from the `api/`
  `/api/standard-site` endpoint — the actual AT Protocol / Bluesky PDS publishing now
  lives in `api/`, webhook-driven).
  (robots.txt is a static Middleman template, `source/robots.txt.erb`, built here.)
- **Page generation**: Middleman proxies (`config.rb`) turn `data/*.json` into static
  pages — articles, pages, tags, blog index.
- **Runtime dynamic content**: weather, activity stats, Whoop, per-article pageviews,
  and event weather are **not built here**. The `live-update` Stimulus controller
  fetches them client-side from `/api/*` into placeholder partials (root `CLAUDE.md`).

## Commands

Run `nvm use` before any `npm` command.

```bash
# Tests — single file (fast) then full suite
bundle exec rspec spec/lib/helpers/markup_helpers_spec.rb
bundle exec rake test

# Local dev
bundle exec rake import          # fetch fresh data first
bundle exec middleman            # dev server
npm run watch                    # JS/CSS rebuild on change (separate terminal)

# Lint / format
npm run lint:scss                # stylelint (fix: npm run lint:scss:fix)
npm run format:check             # prettier for JS/JSON/MD (fix: npm run format)

# JS build — required after any JS change
npm run build

# Full production build: test → import → npm build → middleman build
bundle exec rake build:verbose
```

### Import subtasks

Only these exist: `rake import` (runs all in parallel), `import:content` (Contentful),
`import:icons` (Font Awesome), `import:standard_site` (fetches the standard.site DID +
publication URI from the `api/` `/api/standard-site` endpoint). Also `rake redis:empty`
to flush the cache.

## Key locations

- `config.rb` — Middleman config + proxy setup; `Rakefile` — Redis init + task loader.
- `lib/data/*.rb` — build-time clients: `contentful.rb`, `font_awesome.rb` (+ `graphql/`).
- `lib/tasks/*.rake` — `import`, `build`, `test`, `maps`, `redis`.
- `lib/helpers/*.rb` — 13 helper modules (article, markup, image, site, unit, share, icon,
  url, text, markdown, context, cache, affiliate_links);
  `helpers/custom_helpers.rb` registers them.
- `source/layouts/layout.erb`, `source/partials/` (incl. `placeholders/`),
  `source/javascripts/stimulus/`, `source/stylesheets/`.
- `netlify/functions/` — `api-proxy.mts` (proxies `/api/*`; see root `CLAUDE.md`),
  `og.mts` (OG images).
- `netlify/edge-functions/` — `known-agents.ts` (records every page view server-side to
  Known Agents / Dark Visitors, capturing bot + AI-agent traffic Plausible can't see;
  production-only, reuses `DARK_VISITORS_ACCESS_TOKEN`).
- `data/font_awesome.yml` — **icon allowlist**. Any new icon must be added here (under
  the correct family/style, e.g. `classic.light`) before `icon_svg` / `rake import:icons`
  can use it.

## Environment variables

Names only — see `.env.example`; never commit values.

- **Required**: `CONTENTFUL_SPACE`, `CONTENTFUL_TOKEN`, `FONT_AWESOME_API_TOKEN`,
  `REDIS_URL`, `KONA_API_URL` (base URL of the `api/` app — used by the `/api/*` proxy
  and the `import:standard_site` fetch), `API_TOKEN` (shared bearer the `/api/*` proxy
  injects on every upstream request; **must match the `api/` app's `API_TOKEN`**, and must be
  set in Netlify's runtime env or every widget 401s at the origin and collapses on the site).
- **Build credential**: `WEBAWESOME_NPM_TOKEN` — Web Awesome Pro npm registry auth, read
  by `.npmrc` at `npm install` (not in `.env`). Set it in your shell and in Netlify's
  build env, or the install fails.
- **Optional**: `DARK_VISITORS_ACCESS_TOKEN`, `CLOUDFRONT_DOMAIN`.

## Conventions & gates

- **Before committing** (non-negotiable): `bundle exec rake test` passes →
  `npm run lint:scss` + `npm run format:check` clean → `npm run build` if you changed
  JS → `bundle exec rake build:verbose` succeeds. Follow `.editorconfig`.
- **Netlify**: build tools must be in `dependencies`, not `devDependencies` — Netlify
  installs with `NODE_ENV=production` and skips `devDependencies`.
- **Tests** live in `spec/` and focus on helpers, text/markdown processing, and data
  transformation.
- **Widget markup**: editing a placeholder partial means editing the matching `api/`
  view too (root `CLAUDE.md`).

### Permissions

- Autonomous: read files, single-file `rspec`, lint/format, local `middleman`.
- Ask first: `git push`/commit, `rake redis:empty`, package installs, anything that
  triggers a deploy or build hook.
