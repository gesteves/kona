# og/ — Kona Open Graph card service

A tiny standalone Node service (Node LTS, pinned via `.nvmrc`; `node:http`, no framework) that renders the
1200×630 Open Graph "card" images on demand, deployed to fly.io as **`kona-og`** and served
behind Cloudflare. It replaced the build-time pre-render (the old `web/scripts/render-og.mjs`
+ `build/og/*.png`), so cards are no longer generated during the Netlify build.

The card is only used as the `og:image` for pages **without** a cover image (Shorts, some
content pages); pages with a cover image use a Cloudflare-cropped version of that image
instead (`open_graph_image_url` on the web side).

## Request contract

```
GET /og.png?url=<page url>&v=<template ver>-<publishedVersion>   → 1200×630 image/png
GET /up                                                          → 200 health check
```

- **`url`** — the page whose card to render. Its origin must be on the `SITE_URL` allowlist,
  or the request is rejected (403) before any fetch. The service fetches that page and reads
  its own `<meta property="og:title">` (which the site sets to `page_title(...)`) — that's
  the card title. So the service can only ever render titles of real, published pages; it
  never renders caller-supplied text.
- **`v`** — an opaque **cache buster**; the service does nothing with it. The web helper
  (`generate_open_graph_image_url` in `web/lib/helpers/image_helpers.rb`) builds it from a
  `TEMPLATE_VERSION` constant plus the entry's `sys.published_version`. A republish bumps
  `published_version` → the page emits a new `og:image` URL → a fresh render on next crawl,
  with the old immutable card left to age out. **No purge is ever needed.** A card-design or
  logo change is rolled out by bumping `TEMPLATE_VERSION` on the web side.

Successful renders are served `Cache-Control: public, max-age=31536000, immutable` +
`CDN-Cache-Control: public, max-age=31536000`; this is safe because the URL is
content-addressed on `(url, v)`. Errors get a short TTL so a blip is never durably cached.

## Baked assets — `assets/`

- `IBMPlexSansCondensed-Bold.ttf` — the title font (copied from `web/source/fonts/`).
- `logo.png` — the site logo, drawn at the top of every card. ⚠️ **Must stay a PNG**: satori
  can't decode webp/avif and the transparency must survive. To change the logo, replace this
  file **and** bump `TEMPLATE_VERSION` on the web side so cached cards refresh, then redeploy.

## Key files

- `server.mjs` — `node:http` server + routing + cache headers.
- `render.mjs` — the satori (`@vercel/og`) card template (ported verbatim from the old
  `web/scripts/render-og.mjs`) + baked font/logo.
- `title.mjs` — the `SITE_URL` origin allowlist and the `og:title` fetch/parse.

## Local dev

```bash
nvm use            # Node LTS, from .nvmrc
npm install
SITE_URL=http://localhost:4567 npm start   # then GET /og.png?url=<a page on that origin>&v=v1-1
```

## Environment

Names only — see `.env.example`; never commit values.

- **Required**: `SITE_URL` (comma-separated origin allowlist; NEVER hardcode the production
  hostname). Set as a fly secret on `kona-og`.
- **Optional**: `PORT` (defaults to 3000, matching `fly.toml` `internal_port`).

## Deploy

fly.io app `kona-og` (`fly.toml`), single HTTP process, auto start/stop. CI deploys on push
to `main` when `og/**` changes (`.github/workflows/og.yml`) via `flyctl deploy --remote-only`.
Cloudflare fronts it (a proxied hostname → this app, dashboard-side); the web build reaches
it through its `OG_IMAGE_URL` env var. Nothing in this repo configures the zone.
