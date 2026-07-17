# kona-og

A tiny Node service that renders the Open Graph "card" image (the `og:image` for pages
without a cover image) on demand for the otherwise-static [Kona](../README.md) site.
Deployed to fly.io and fronted by Cloudflare; the [`web/`](../web/README.md) site points its
`og:image` tags at it via the `OG_IMAGE_URL` env var. It replaced a build-time pre-render, so
cards are no longer generated during the Netlify build.

## How it works

```
GET /og.png?url=<page url>&v=<template ver>-<publishedVersion>   → 1200×630 image/png
GET /up                                                          → health check
```

On a request, the service checks that `url`'s origin is on the `SITE_URL` allowlist, fetches
that page, reads its own `<meta property="og:title">`, and renders a 1200×630 PNG (site logo
above the title). Because the title comes from the page itself, the service can only ever
render cards for real, published pages — it never renders caller-supplied text.

`v` is a pure **cache buster**; the service ignores it. The web helper builds it from a
template-version constant plus the entry's Contentful `publishedVersion`. A republish bumps
`publishedVersion`, so the page emits a new card URL and a title edit is picked up on the
next crawl — the old card (served `Cache-Control: immutable` for a year) is simply never
requested again. **No cache purge is ever needed.** A card-design or logo change is rolled
out by bumping the template version on the web side.

The site logo and title font are baked into `assets/` (see [`CLAUDE.md`](CLAUDE.md)).

## Setup

Copy `.env.example` to `.env` for local development; in production set these as fly secrets
(`fly secrets set KEY=value`). See `.env.example` for the full list and notes.

- **`SITE_URL`** (required) — comma-separated allowlist of site origins the `url` param may
  point at (production plus any preview origin). A request whose `url` isn't on one of these
  is rejected before any fetch. Never hardcode the production hostname.
- **`PORT`** (optional) — the port the server binds to; defaults to `3000`.

## Running locally

Requirements: Node LTS — run `nvm use` to pick it up from `.nvmrc`.

1. Copy `.env.example` to `.env` and set `SITE_URL` (e.g. `http://localhost:4567` to point at
   a local `middleman server`).
2. Install dependencies: `npm install`.
3. Start the server: `SITE_URL=http://localhost:4567 npm start` — it runs at
   `http://localhost:3000`. Then request a card:
   `http://localhost:3000/og.png?url=http://localhost:4567/<a page>/&v=v1-1`.

## Common commands

| Command | Description |
| --- | --- |
| `npm start` | Start the server |
| `node --check server.mjs` | Syntax-check the entry point |
| `fly deploy` | Deploy to fly.io |
| `fly logs` | Tail the deployed app's logs |

## Deployment

Deployed to fly.io as `kona-og`: `fly deploy` (CI does this on push to `main` when `og/**`
changes — see `.github/workflows/og.yml`). Configure the origin allowlist with
`fly secrets set SITE_URL=…`. A Cloudflare-proxied hostname points at the app (dashboard-side;
nothing in this repo configures the zone).
