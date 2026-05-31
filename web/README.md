# kona-web

[![Netlify Status](https://api.netlify.com/api/v1/badges/f87f4e00-a5a5-436d-b6df-a3628c3fb919/deploy-status)](https://app.netlify.com/sites/giventotri/deploys)

The blog itself: a [Middleman](https://middlemanapp.com/) static site powered by [Contentful](https://www.contentful.com/) and hosted on [Netlify](https://www.netlify.com/). Live home-page widgets (weather, activity stats, Whoop, pageviews) are served at runtime by the [`api/`](../api/README.md) app through a Netlify `/api/*` proxy.

Kona uses Middleman [data files](https://middlemanapp.com/advanced/data-files/): it calls various services at build time, manipulates the responses, and writes them as JSON to `data/`, where they're available to templates and helpers.

## Setup

Copy `.env.example` to `.env` and fill in the credentials below (also add them to the site's environment variables in Netlify). See `.env.example` for the full list and notes.

### Required services

- **Netlify** — hosting. Kona can run anywhere as a static site, but relies on Netlify [functions](https://docs.netlify.com/functions/overview/) (the `/api/*` proxy, OG images), [Image CDN](https://docs.netlify.com/image-cdn/overview/), and [build hooks](https://docs.netlify.com/configure-builds/build-hooks/).
- **Contentful** — the CMS for the site's content. Create an API key under Settings → API Keys and set `CONTENTFUL_SPACE` and `CONTENTFUL_TOKEN` (Content Preview token). You'll want a content model like this:

  <img width="1616" height="3182" alt="Contentful content model" src="https://github.com/user-attachments/assets/689d3caf-8b71-47a4-95e5-4630bf9c8281" />

- **Font Awesome** — icons, pulled from the API at build time. Needs a Pro account and a token with the "Pro icons and metadata" read scope. Set `FONT_AWESOME_API_TOKEN`.
- **Redis** — caches API responses to speed up builds. Set `REDIS_URL`.
- **Kona API** — set `KONA_API_URL` to the deployed [`api/`](../api/README.md) app. The home-page weather/stats/Whoop widgets load from it at runtime, and `rake import:location` fetches the current location at build time.

### Optional services

- **Plausible** — traffic analytics, used to surface trending articles. Set `PLAUSIBLE_SITE_ID` and `PLAUSIBLE_API_KEY`.
- **Dark Visitors** — imports `robots.txt` directives to deter AI scrapers. Set `DARK_VISITORS_ACCESS_TOKEN`.
- **CloudFront** — serves Contentful images via a CDN to avoid bandwidth limits. Set `CLOUDFRONT_DOMAIN`.
- **Bluesky** — syncs posts to the AT Protocol (standard.site). Set `BLUESKY_HANDLE`, `BLUESKY_APP_PASSWORD`, `BLUESKY_PDS_URL`.
- **Netlify build hook** — rebuilds the site on a schedule to pick up new content. Set `BUILD_HOOK_URL`.

## Running locally

Requirements: Ruby, Node, and the [Netlify CLI](https://docs.netlify.com/cli/get-started/).

1. Add the environment variables to `.env` (or the site config in Netlify).
2. Install dependencies: `bundle install` and `npm install`.
3. Build the site (runs the data import): `netlify build`.
4. Start the local server: `netlify dev`.
5. In another tab, watch JS/CSS: `npm run watch`.
6. To refresh data without a full rebuild: `bundle exec rake import`.

## Common commands

| Command | Description |
| --- | --- |
| `bundle exec rake import` | Import all build-time data |
| `bundle exec rake import:content` | Import Contentful content only |
| `bundle exec rake import:icons` | Import Font Awesome icons only |
| `bundle exec rake import:location` | Fetch the current location from the API |
| `bundle exec rake import:standard_site` | Sync posts to Bluesky |
| `bundle exec rake test` | Run the test suite |
| `bundle exec rake build:verbose` | Full build: test → import → JS build → Middleman |
| `npm run build` | Build the JavaScript bundle (required after JS changes) |
| `npm run watch` | Rebuild JS/CSS on change |
| `npm run lint:scss` / `npm run format:check` | Lint SCSS / check JS, JSON, MD formatting |
| `bundle exec rake redis:empty` | Flush the Redis cache |
