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

- **Font Awesome** — icons. This app holds no Font Awesome token: `rake import:icons` sends the list in `data/font_awesome.yml` to the [`api/`](../api/README.md) app (`POST /api/icons`), which holds the token and returns the SVG data. Thus the import needs `KONA_API_URL` and `API_TOKEN`, and a new icon needs a line in that list.
- **Web Awesome Pro** — the web component library the UI is built on. Needs a Pro subscription; the private registry is configured in `.npmrc`, and `npm install` reads `WEBAWESOME_NPM_TOKEN` from the environment to authenticate. Set it locally (your shell) and in the build environment.
- **Redis** — the cache of the build. It holds the blurhash placeholder of each image, thus a build does not decode each one again, and the state of IndexNow (the sitemap of the last submission). Set `REDIS_URL`.
- **Kona API** — set `KONA_API_URL` to the deployed [`api/`](../api/README.md) app. The home-page weather/stats/Whoop widgets load from it at runtime.
- **Cloudflare R2** — a bucket mirroring Contentful's image assets, so Cloudflare Images fetches its source from a hostname inside the zone rather than from Contentful. A source outside the zone can't use Tiered Cache or Cache Reserve, so every Cloudflare PoP otherwise pulls the full-size original from Contentful and re-pulls it on eviction — which is what this is for. Attach a custom domain to the bucket and set `IMAGE_HOST` to that hostname, then allowlist **that host and only that host** as a Transformations source. ⚠️ Don't allowlist `*.ctfassets.net`: with the mirror host as the only allowed source, a missing or wrong `IMAGE_HOST` 403s loudly instead of silently falling back to Contentful and billing its metered bandwidth. That's also why `IMAGE_HOST` is required rather than optional. ⚠️ The **api** app populates the bucket, webhook-driven; run its `rake assets:backfill` before setting `IMAGE_HOST`, or every image 404s.
- **Known Agents** _(optional)_ — the [AI agent catalogue](https://knownagents.com/) that was Dark Visitors. `rake import` posts the "AI Data Scraper" agent type to its API and the build writes the `Disallow` rules it returns into `/robots.txt`, so the blocklist tracks the agent landscape without an edit here. Make an account to get an access token and set `KNOWN_AGENTS_ACCESS_TOKEN`, locally and in the build environment. Unset, the import writes nothing and `/robots.txt` keeps its catch-all rule only.

## Running locally

Requirements: Ruby and Node.

1. Add the environment variables to `.env`.
2. Install dependencies: `bundle install` and `npm install` (the latter needs `WEBAWESOME_NPM_TOKEN` set — see Web Awesome Pro above).
3. Build the site (runs the data import): `bundle exec rake build`.
4. Start the local server: `bundle exec middleman` (it runs the esbuild watcher itself, so JS/CSS rebuild on change automatically).
5. To refresh data without a full rebuild: `bundle exec rake import`.

`/widgets/*` and `POST /api/contact` are Worker routes with no page behind them, so `lib/utils/dev_api_proxy.rb` — a dev-only Rack middleware — forwards them to `KONA_API_URL` with the bearer injected. Without it every widget would collapse. It runs only under `middleman server`, never in a build.

To run the site against a local [`api/`](../api/README.md) instead of the deployed one, use `overmind start` from the repo root; see the root [`CLAUDE.md`](../CLAUDE.md).

The remaining Worker routes — `/pa/*` and the on-demand Open Graph cards — still need the real Worker:

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
| `bundle exec rake import:related` | Fetch the related-articles ranking from the API |
| `bundle exec rake import:known_agents` | Fetch the AI-scraper robots.txt rules from Known Agents |
| `bundle exec rake import:schema` | Write the Contentful GraphQL schema to `lib/data/graphql/contentful_schema.json` |
| `bundle exec rake test` | Run the Ruby specs |
| `bundle exec rake build` | Full build: import → Middleman (which runs the JS build) → Pagefind. It does **not** run the tests |
| `bundle exec rake build:verbose` | The same build, with the verbose output of Middleman |
| `bundle exec rake build:fast` | Build from the existing `data/`, skipping the import |
| `bundle exec rake indexnow:submit` | Submit the URLs that changed since the last submission to IndexNow (`DRY_RUN=1` prints them only) |
| `npm run lint:scss` / `npm run format:check` | Lint SCSS / check JS, JSON, MD formatting |
| `bundle exec rake redis:clear` | Flush the Redis cache |

## How a build runs

`bundle exec rake build` does these steps, in this order. The files are `Rakefile`, `lib/tasks/*.rake`, and `config.rb`.

1. **The Rakefile loads the data layer** (`lib/data/*.rb`), for each rake task. That reads the Contentful GraphQL schema from `lib/data/graphql/contentful_schema.json`, or from Contentful when the file is absent.
2. **`clobber` deletes `data/*.json`.** Thus each import starts with no old data. The two YAML files in `data/` stay: a person writes them.
3. **Six importers run at the same time** (`lib/tasks/import.rake`):

   | Importer | Source | Writes | When it fails |
   | --- | --- | --- | --- |
   | `import:content` | Contentful | `articles`, `assets`, `blog`, `events`, `pages`, `redirects`, `site`, `tags` (`.json`) | The build stops |
   | `import:icons` | `api/` | `icons.json` | The build stops |
   | `import:related` | `api/` | `related.json` | A warning. No article has "You May Also Like" |
   | `import:standard_site` | `api/` | `standard_site.json` | A warning. No page has the verification tags |
   | `import:known_agents` | Known Agents | `known_agents.json` | A warning. `robots.txt` keeps its catch-all rule only |
   | `import:schema` | Contentful | The schema file of step 1, for the next run | A warning |

4. **Middleman reads `config.rb`**, which gives each module in `lib/helpers/` to the templates and then makes the pages from the data:
   - each article, Short, page, blog index page, and tag archive page, with the template that its data names (refer to [Which template renders what](#which-template-renders-what));
   - a Markdown copy of each published post, at `<permalink>index.md`;
   - an Atom feed for each tag, at `<tag path>feed.xml`;
   - `/.well-known/about.md`.
5. **Before the first page**, `config.rb` reads each blurhash placeholder from Redis one time, and Middleman runs `npm run build`: esbuild puts the Stimulus and Turbo JavaScript into `tmp/dist`, which Middleman reads as a part of `source/`. Middleman gives each asset a fingerprint, and a production build also minifies the CSS and the HTML.
6. **After Middleman**, `lib/tasks/build.rake` renames `build/redirects` and `build/headers` to `_redirects` and `_headers`, which Cloudflare reads, and `npm run pagefind` makes the search index from `build/`.
7. **In CI** (`.github/workflows/web.yml`), the deploy job then checks `build-id.txt`, runs `wrangler deploy`, purges the `site` cache tag, and submits the changed URLs to IndexNow.

`rake build:fast` starts at step 4, with the `data/` that is on the disk.

## Where things are

One row for each feature, and each file that it goes through. A helper is a module in `lib/helpers/`, and each template can call each helper. A partial is in `source/partials/`. A controller is in `source/javascripts/stimulus/controllers/`, and a lib is in `source/javascripts/stimulus/lib/`. The Worker is in `src/`.

| Feature | Data | Helpers | Templates | Site JavaScript | Worker |
| --- | --- | --- | --- | --- | --- |
| Article page | `articles.json` | `article_helpers`, `markup_helpers` (the body), `image_helpers` | `article.html.erb` → `article/_full`, `article/_meta`, `article/_body`, `_share` | `publish_date`, `units`, `image_placeholder`, `lib/eager_print_images` | — |
| Short | `articles.json` | the same | `short.html.erb` → `article/_short` | the same | — |
| Page, and the home page | `pages.json` | `markup_helpers`, `site_helpers` | `page.html.erb`, `home.html.erb` → `article/_page`, `article/_body` | — | — |
| Blog index and tag archives | `blog.json`, `tags.json` | `article_helpers` (the taxonomy) | `articles.html.erb`, `tag.html.erb` → `_blog_list` → `article/_compact`, `article/_short` | — | — |
| Recirculation ("More Reports From This Race", "You May Also Like", Previous and Next) | `related.json`, `articles.json` | `article_helpers` (`recirculation_sections`, `related_articles`, `adjacent_articles`) | `_recirculation`, `_related`, `_read_next` → `_collection` → `article/_summary` | — | — |
| Cover images and placeholders | `assets.json`, `srcsets.yml` | `image_helpers` (`cover_image_tag`, `srcset`, the blurhash), `markup_helpers` (the images of a body) | `article/_summary`, `article/_compact` | `image_placeholder` | — |
| Live widgets (stats, Whoop, weather, trending, upcoming races) | `events.json` for the races | `site_helpers` (`render_widget`, `live_update_attrs`), `event_helpers` | `placeholders/*`, `_upcoming_races` | `live_update` | `api-proxy.ts` (`/widgets/*`) |
| Contact form | — | `site_helpers` (`turnstile_site_key`) | `_contact_form`, from `article/_body` on the page with the slug `contact` | `contact`, `lib/utils` (the toast) | `api-proxy.ts` (`POST /api/contact`) |
| Search | The Pagefind index in `build/pagefind/` | — | `_search_trigger`, `_nav`, `_footer` | `search`, `lib/pagefind` | — |
| Analytics | — | `site_helpers` (`plausible_*`, `article_click_classes`), `csp_helpers` | `_analytics` | `lib/analytics`, which `page`, `search`, `share`, and `clipboard` call | `plausible.ts` (`/pa/*`) |
| Open Graph image | `assets.json` | `image_helpers` (`open_graph_image_url`, `generate_open_graph_image_url`) | `_open_graph_and_social` | — | `og.ts`, `og-render.ts` (a page with no cover image) |
| Structured data (JSON-LD) | — | `schema_helpers`, `article_helpers` (`article_schema`, `breadcrumb_schema`), `event_helpers` | `schema/*`, from `_head` | — | — |
| Feeds | `articles.json`, `tags.json` | `article_helpers` (`feed_articles`), `markup_helpers` (`render_feed_body`), `site_helpers` (`feed_title`) | `feed.xml.erb`, `tag_feed.xml.erb` → `_feed` | — | — |
| Markdown copies | `articles.json`, `pages.json` | `entry_markdown_helpers`, `about_helpers`, `markdown_document_helpers` | `entry_md.txt.erb`, `about_md.txt.erb` | — | — |
| Share buttons | — | `share_helpers` | `_share` | `share`, `clipboard` | — |
| Header, nav, footer | `site.json` | `site_helpers` (the links, the copyright) | `_header`, `_nav`, `_footer`, `_logo.svg`, `_logo_symbol.svg` | `nav`, `back_to_top`, `current_year` | — |
| Icons | `font_awesome.yml`, `icons.json` | `icon_helpers` | each template, through `icon_svg` | — | — |
| Redirects and security headers | `redirects.json` | `redirect_helpers`, `csp_helpers` | `redirects.erb`, `headers.erb` | — | `headers.ts` (the Worker routes) |
| `robots.txt`, `llms.txt`, sitemap, IndexNow | `known_agents.json` | `site_helpers`, `article_helpers` (`llms_articles`) | `robots.txt.erb`, `llms.txt.erb`, `sitemap.xml.erb`, `indexnow.txt.erb` | — | — |
| standard.site verification | `standard_site.json` | `standard_site_helpers` | `_head`, `.well-known/site.standard.publication.erb` | — | — |

Two more places: `lib/utils/dev_api_proxy.rb` does the work of `api-proxy.ts` for `middleman server`, and `lib/utils/index_now.rb` holds the IndexNow submission that `rake indexnow:submit` runs.

## Which template renders what

No page template is a page by itself. `config.rb` makes each page from an item of the data, and the item names its template. `Contentful#set_template` and `Contentful#listing_page` (`lib/data/contentful.rb`) set that name:

| Item | Template |
| --- | --- |
| An Article | `source/article.html.erb` |
| A Short | `source/short.html.erb` |
| The Page that is the home page | `source/home.html.erb` |
| Each other Page | `source/page.html.erb` |
| A page of the blog index (`data/blog.json`) | `source/articles.html.erb` |
| A page of a tag archive (`data/tags.json`) | `source/tag.html.erb` |

`source/layouts/layout.erb` is the one layout. It puts `_head`, `_skip`, `_header`, `_footer`, `_notifications`, and `_logo_symbol.svg` around each page, and `_head` renders `_meta`, `_open_graph_and_social`, the `schema/*` partials, and `_analytics`.

The partials of each page, below the layout:

- **Home** (`home.html.erb`): the `stats`, `whoop`, `trending`, and `weather` placeholders (`render_widget`), `_collection` → `article/_summary` → `article/_meta` for the recent articles, and `_upcoming_races`.
- **Article** (`article.html.erb`): `article/_full` → `article/_meta` and `article/_body` (→ `_contact_form`, `_disclosure`); then `_share`; `_recirculation` → `_collection` → `article/_summary`; `_read_next` → `article/_summary`.
- **Short** (`short.html.erb`): `article/_short`; then `_share`; `_related` → `_collection`; `_read_next`.
- **Blog index and tag archive** (`articles.html.erb`, `tag.html.erb`): `_blog_list` → `article/_compact` for an Article and `article/_short` for a Short.
- **Page** (`page.html.erb`): `article/_page` → `article/_body`; then the `trending` placeholder, when the Page has `show_recommendations` on.

Three names need care. `partials/article/` also holds the partials of a Short and of a Page. `_collection.html.erb` is a section of article cards, `placeholders/_article_collection` is the skeleton of the trending widget, and `schema/_collection` is the JSON-LD of a tag archive. `partials/placeholders/` holds the skeletons of the live widgets, and the placeholder of an image is a different thing (`image_helpers`, `_placeholder.scss`).
