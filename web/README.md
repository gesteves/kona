# kona-web

The blog itself: a [Middleman](https://middlemanapp.com/) static site powered by [Contentful](https://www.contentful.com/) and served by a [Cloudflare Worker](https://developers.cloudflare.com/workers/static-assets/). Live home-page widgets (weather, activity stats, Whoop, pageviews) are served at runtime by the [`api/`](../api/README.md) app.

Kona uses Middleman [data files](https://middlemanapp.com/advanced/data-files/): it calls various services at build time, manipulates the responses, and writes them as JSON to `data/`, where they're available to templates and helpers.

## Setup

Copy `.env.example` to `.env` and fill in the credentials below (deploys read them from the "Web" workflow's secrets, and the Worker's runtime vars come from the Cloudflare dashboard). See `.env.example` for the full list and notes.

### Required services

- **Cloudflare Workers** — hosting. The build is uploaded as [static assets](https://developers.cloudflare.com/workers/static-assets/) on the `kona-web` Worker (`wrangler.jsonc`), which also runs the `/widgets/*` and `POST /api/contact` proxy, the first-party analytics proxy, and the on-demand Open Graph card renderer (`<page path>og.png` — the `og:image` for posts with no cover image, drawn with satori + resvg from the page's own `og:title`). Kona can run anywhere as a static site, but those dynamic routes need the Worker (or an equivalent). ⚠️ The card renderer needs the **Workers Paid** plan: a render is ~100 ms of CPU, against the Free plan's 10 ms per-request limit.
- **Cloudflare** — the zone in front of the site. Images are resized and served through [Cloudflare Images](https://developers.cloudflare.com/images/transform-images/transform-via-url/) (`/cdn-cgi/image/…`), which fetches the untransformed source image and caches the results at the edge. Requires Transformations enabled on the zone, with the source host allowlisted — without that, every image 403s.
- **Contentful** — the CMS for the site's content. Create an API key under Settings → API Keys and set `CONTENTFUL_SPACE` and `CONTENTFUL_TOKEN` (Content Preview token). You'll want a content model like this:

  <img width="1616" height="3182" alt="Contentful content model" src="https://github.com/user-attachments/assets/689d3caf-8b71-47a4-95e5-4630bf9c8281" />

- **Font Awesome** — icons, pulled from the API at build time. Needs a Pro account and a token with the "Pro icons and metadata" read scope. Set `FONT_AWESOME_API_TOKEN`.
- **Web Awesome Pro** — the web component library the UI is built on. Needs a Pro subscription; the private registry is configured in `.npmrc`, and `npm install` reads `WEBAWESOME_NPM_TOKEN` from the environment to authenticate. Set it locally (your shell) and in the build environment.
- **Redis** — caches API responses to speed up builds. Set `REDIS_URL`.
- **Kona API** — set `KONA_API_URL` to the deployed [`api/`](../api/README.md) app. The home-page weather/stats/Whoop widgets load from it at runtime.
- **Cloudflare R2** — a bucket mirroring Contentful's image assets, so Cloudflare Images fetches its source from a hostname inside the zone rather than from Contentful. A source outside the zone can't use Tiered Cache or Cache Reserve, so every Cloudflare PoP otherwise pulls the full-size original from Contentful and re-pulls it on eviction — which is what this is for. Attach a custom domain to the bucket and set `IMAGE_HOST` to that hostname, then allowlist **that host and only that host** as a Transformations source. ⚠️ Don't allowlist `*.ctfassets.net`: with the mirror host as the only allowed source, a missing or wrong `IMAGE_HOST` 403s loudly instead of silently falling back to Contentful and billing its metered bandwidth. That's also why `IMAGE_HOST` is required rather than optional. ⚠️ The **api** app populates the bucket, webhook-driven; run its `rake assets:backfill` before setting `IMAGE_HOST`, or every image 404s.

## Running locally

Requirements: Ruby and Node.

1. Add the environment variables to `.env`.
2. Install dependencies: `bundle install` and `npm install` (the latter needs `WEBAWESOME_NPM_TOKEN` set — see Web Awesome Pro above).
3. Build the site (runs the data import): `bundle exec rake build`.
4. Start the local server: `bundle exec middleman` (it runs the esbuild watcher itself, so JS/CSS rebuild on change automatically).
5. To refresh data without a full rebuild: `bundle exec rake import`.

The dynamic routes (`/widgets/*`, `POST /api/contact`, `/pa/*`) and the on-demand Open Graph cards are Worker code, so they don't run under `middleman server` — the widgets simply collapse. To exercise them, run the Worker instead:

```sh
bundle exec rake build:fast   # rebuild build/ from the data already imported
npx wrangler dev              # http://localhost:8787
```

`wrangler dev` serves the `build/` directory rather than `source/`, so re-run `build:fast` after each change. It reads `.env` for `KONA_API_URL` and `API_TOKEN`, so the widgets hit whichever API that file names — point it at a local [`api/`](../api/README.md) to run both apps together.

## Common commands

| Command | Description |
| --- | --- |
| `bundle exec rake import` | Import all build-time data |
| `bundle exec rake import:content` | Import Contentful content only |
| `bundle exec rake import:icons` | Import Font Awesome icons only |
| `bundle exec rake import:standard_site` | Fetch standard.site verification data from the API |
| `bundle exec rake test` | Run the test suite |
| `bundle exec rake build:verbose` | Full build: test → import → Middleman (which runs the JS build) |
| `bundle exec rake build:fast` | Build from the existing `data/`, skipping the import |
| `npm run lint:scss` / `npm run format:check` | Lint SCSS / check JS, JSON, MD formatting |
| `bundle exec rake redis:clear` | Flush the Redis cache |
