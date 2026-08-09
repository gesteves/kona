# web/ — Kona static site

Middleman 4 static site generator (Ruby 4.0.6) building a **Contentful**-powered blog, deployed to
the **`kona-web` Cloudflare Worker**, which serves the build as static assets. esbuild bundles the
JavaScript (Stimulus + Turbo) and the **Web Awesome Pro** theme CSS through Middleman's external
pipeline; Sass compiles the rest. UI components come from Web Awesome Pro, imported in
`source/javascripts/stimulus/index.js`.

Weather, activity, and Whoop data live in `api/` and load at runtime. See the root
[`CLAUDE.md`](../CLAUDE.md) for the web↔api contract before touching any widget markup, and for
the comment-style conventions this app follows.

## Commands

Run `nvm use` before any `npm` command. Native dependency: **libvips** (`brew install vips`) — the
blurhash placeholders render through `ruby-vips` (chosen over ImageMagick because Cloudflare
Workers Builds preinstalls libvips).

```bash
# Ruby tests (Middleman helpers)
bundle exec rspec spec/lib/helpers/markup_helpers_spec.rb   # single file
bundle exec rake test                                       # full suite

# JS tests — Vitest, two projects (see "JavaScript tests")
npm test                              # both
npx vitest run --project worker       # src/*.ts only
npx vitest run --project browser      # source/javascripts/** only

npm run check                         # tsc --noEmit: src/ (tsconfig.json) then test/ (tsconfig.test.json)

# Local dev — see "The two local loops" below
bundle exec rake import               # fetch fresh data first
overmind start                        # from the repo root: :4567 + the api on :3000
bundle exec middleman                 # :4567 alone, against the deployed api
bundle exec rake build:fast           # rebuild build/ from existing data/, no import
npx wrangler dev                      # :8787, the Worker, serving build/

# Lint / format
bundle exec rubocop                   # Ruby; -a to autocorrect. Same ruleset as api/ — see api/CLAUDE.md
npm run lint:js                       # fix: npm run lint:js:fix
npm run lint:scss                     # fix: npm run lint:scss:fix
npm run format:check                  # fix: npm run format

bundle exec rake build:verbose        # full production build — the gate. build:fast is NOT.

# Deploy control (needs the gh CLI) — e.g. a content freeze during a bulk migration
gh workflow disable web.yml           # stop deploying
gh workflow enable web.yml
gh workflow run web.yml               # trigger one build from main
```

### The two local loops

Neither one is the whole site; pick by what you're editing.

| | `middleman` (:4567) | `wrangler dev` (:8787) |
|---|---|---|
| Serves | `source/`, re-rendered per request | `build/`, as deployed |
| Reflects an edit | on reload | only after a rebuild |
| `/widgets/*`, `POST /api/contact` | ✓ via `lib/utils/dev_api_proxy.rb` | ✓ the real Worker |
| `/pa/*`, OG cards | ✗ | ✓ |

Widget **markup** can therefore be developed on :4567; what still needs :8787 is Worker code
itself, the Plausible proxy, and the cards. Root [`CLAUDE.md`](../CLAUDE.md) covers the proxy and
`overmind start`.

So Worker work, widget markup, and OG cards mean `rake build:fast` → `npx wrangler dev`, and
another `build:fast` after every source change. `build:fast` skips `import`, which `rake build`
and `build:verbose` always run: ~2s of a ~9s warm build, but it re-clobbers `data/` and is the
loop's only network dependency. Skipping it means the rebuild works offline and can't be killed
by a flaky `import:icons` (which raises by design) or by the api's fly machine cold-starting
through six sequential `/api/icons` round trips.

`wrangler dev` needs no setup beyond `.env`: with no `.dev.vars` present, wrangler falls back to
`.env`/`.env.local` in this directory, so `KONA_API_URL` and `API_TOKEN` are already bound and the
widgets on :8787 hit whichever api that file names. Point `KONA_API_URL` at a local `api/bin/dev`
to work against both apps at once.

### Import subtasks

`rake import` runs all three in parallel: `import:content` (Contentful), `import:icons` (POSTs the
`data/font_awesome.yml` allowlist to the api's `/api/icons` and writes `data/icons.json`), and
`import:standard_site` (fetches the DID + publication URI from the api). Also `rake redis:clear`.

⚠️ A failed `import:icons` **raises** — icons are an every-page dependency, so the build fails
loudly rather than shipping pages with missing icons. `import:standard_site` degrades gracefully.

## Key locations

- `config.rb` — Middleman config + proxy setup. `Rakefile` — Redis init + task loader.
- `lib/data/` — build-time clients: `contentful.rb` (+ `graphql/`).
- `lib/tasks/` — `import`, `build`, `test`, `redis`.
- `lib/helpers/` — helper modules; `config.rb` requires and registers every module in that
  directory.
- `source/layouts/`, `source/partials/` (incl. `placeholders/`), `source/javascripts/stimulus/`,
  `source/stylesheets/`.
- `src/` + `wrangler.jsonc` — the Cloudflare Worker that **is** the site's hosting.
- `data/font_awesome.yml` — **icon allowlist**. Any new icon must be added here (under the correct
  family/style, e.g. `classic.light`) before `icon_svg` can use it. Adding one is a pure web-side
  yml edit; the api resolves it on demand.

### Render-blocking budget

**Nothing but `stylesheets/site.css` may block the first render.** `_head.html.erb` is arranged so
it's the only blocking stylesheet.

- **Pagefind's CSS/JS are not in the head at all** — `javascripts/stimulus/lib/pagefind.js` injects
  them (idle preload after `load`, intent prefetch on hover/focus, awaited in `search#open`).
  ⚠️ The stylesheet is inserted **before the first existing `<link rel="stylesheet">`**, never
  appended: `stylesheets/components/_pagefind.scss` remaps Pagefind's `--pf-*` vars for dark mode
  from an unlayered `:root` block that wins only by sitting later in *source* order. Append it and
  the modal goes permanently light at night, silently.
- The Web Awesome theme (`/javascripts/site.css`) is still render-blocking and needn't be — it's
  custom-property definitions only. ⚠️ **Do not unblock it with `media="print" onload=…`.** Any
  element with `data-turbo-track="reload"` has its **`outerHTML`** folded into Turbo's tracked-
  element signature, so mutating an attribute at runtime makes every navigation a full page reload,
  silently killing view transitions. Dropping `data-turbo-track` doesn't rescue it either — Turbo
  then appends a duplicate link per navigation. **Never mutate an attribute of a tracked head
  element.** Fixes that work: inline the CSS in a `<style>`, or inject the `<link>` from JS the way
  `lib/pagefind.js` does.
- Above-the-fold woff2 faces are preloaded. `crossorigin` is mandatory even same-origin or they
  download twice; URLs must come from `asset_path(:fonts, …)` because fonts are asset-hashed.

### Open Graph cards

Pages without a cover image get an `og:image` rendered **on demand by this app's own Worker**:
`src/og.ts` (route) + `src/og-render.ts` (the card), claimed as `/og.png` **and** `/*/og.png` in
`run_worker_first`. `generate_open_graph_image_url` builds
`<root_url><page path>og.png?v=<OG_TEMPLATE_VERSION>-<published_version>`. Cover-image pages use
`open_graph_image_url` → Cloudflare Images instead.

- **The page is named by the card's own path**, which is why there are two `run_worker_first`
  entries (a rule is anchored `^…$` with each `*` widened to `.*`) and why the handler has no
  `?path=` parameter to validate. It strips only the **filename**, keeping the trailing slash: the
  built asset is `/post/index.html`, and `html_handling: "auto-trailing-slash"` answers a slashless
  `/post` with a redirect, which the handler's 200-only check reads as a missing page.
- **The title comes from the page's own `og:title`, read through the `ASSETS` binding** — not
  fetched over HTTP. The renderer can only ever draw a title present in the deployed build, so
  there is no caller-supplied text anywhere in the path.
- **Article cards are content-addressed**: a republish bumps `published_version` → new URL.
  ⚠️ Bump `OG_TEMPLATE_VERSION` after editing `og-render.ts`, `src/assets/logo.png`, or the font,
  or the year-cached old cards keep serving.
- ⚠️ **Listing-page cards are NOT self-busting.** The blog index, tag archives, and home aren't
  Contentful entries, so `v` is `OG_TEMPLATE_VERSION` alone and the URL is fixed forever — today
  43 of 73 card-emitting pages. Their `og:title` comes from `data.site.meta_title` or a tag name.
  What refreshes them is the zone's `Cache-Tag: site` deploy purge, which is why the card paths are
  deliberately left tagged (root `CLAUDE.md`).
- ⚠️ **Needs the Workers Paid plan** (~100 ms CPU per render vs Free's 10 ms limit).
- ⚠️ **Renders are covered by `wrangler dev`, not by the test suite** — see **The two local loops**
  and **JavaScript tests**.
- `src/assets/` holds the card's font and logo, imported as Data modules (hence the `rules` entry
  in `wrangler.jsonc`).

### `_headers` and `_redirects`

Built from `source/headers` / `source/redirects.erb` and renamed (underscore-prefixed source files
are treated as partials and skipped).

- ⚠️ In `_headers`, no two rules may set the same header for overlapping paths — matching rules
  comma-join same-name headers on Cloudflare.
- ⚠️ **`_redirects` rule ORDER is load-bearing.** Cloudflare counts 2,000 "static" rules but only
  100 "dynamic" ones, and its `canCreateStaticRule` flag **latches off at the first rule whose
  source has a `*` or `:placeholder`** — every rule after that, even exact-match ones, counts as
  dynamic. So `redirects.erb` emits every exact-match redirect **before** any splat one. Emit a
  splat early and the deploy fails (`code: 100324`) once the file passes ~100 lines. Don't
  hand-place a `*`/`:name` rule above the static block.
- ⚠️ **Cloudflare rejects absolute-URL *sources***, and **200-status proxy rewrites to an absolute
  URL**. Both hard-fail the deploy with a bare `code: 100324`. `redirects.erb` drops them, since
  redirects are authored in Contentful and a mis-entered one would otherwise break the deploy.
  Cross-domain redirects belong in a Cloudflare zone rule / Bulk Redirect.

### The Worker

`wrangler.jsonc` + `src/`: serves `build/` as static assets, plus routes for the widget proxy, the
Plausible proxy (`src/plausible.ts`, not `_redirects` rewrites), the contact form, and OG cards.

⚠️ **`run_worker_first` is a POSITIVE allowlist — only listed paths invoke the Worker.** It lists
exactly the dynamic routes (`/widgets/*`, `/api/contact`, `/pa/*`, `/og.png`, `/*/og.png`);
everything else — every HTML page, fingerprinted asset, the sitemap, the feeds, `/.well-known/*`,
any 404 — comes straight from the static asset layer and costs no Worker invocation. Each listed
route needs the Worker because it has **no asset**. When you add a dynamic route, add its path
here, and mind that Cloudflare globs **cross `/`**.

⚠️ A new entry also needs a matching **exclusion in the zone's edge-TTL Cache Rule** (root
`CLAUDE.md`) — except the OG cards, which that rule's `not path contains "."` clause already
excludes. That is precisely why the OG route carries an extension; don't rename it to something
extensionless without adding the exclusion first.

⚠️ Test tooling is isolated from production types: `tsconfig.test.json` (test/** only, pulls in
`@cloudflare/workers-types`, drops the inherited `dom` lib since lib.dom's `CacheStorage` has no
`caches.default`) is **separate** from `tsconfig.json` (src only, `types: []` + the `env.d.ts`
shims). The two must never share a compile.

⚠️ Between them those two tsconfigs cover `src/` and `test/*.ts` — and nothing else. **ESLint
(`eslint.config.mjs`) exists to cover the rest**: `source/javascripts/**` and `test/browser/**`,
which no typechecker reads. It deliberately does *not* lint `src/**/*.ts`: that needs
typescript-eslint, which still caps its TypeScript peer at `<6.1.0` while this project is on
TypeScript 7. Its type-aware rules call the TS compiler API, so forcing the peer would be broken,
not merely unsupported — revisit when it catches up. ESLint enables **no formatting rules**
(verified: 0 of 64), so Prettier keeps sole ownership of layout and `eslint-config-prettier`
isn't needed.

⚠️ **The pool config is `vitest.config.mts`, not `.ts`** — pool 0.18 is ESM-only, and without
`"type": "module"` in `package.json` Vite loads a `.ts` config as CJS and the import fails.
Outbound fetch mocking is hand-rolled in `test/helpers.ts` (`interceptFetch`); the pool's
`fetchMock` was removed in the same release.

## Environment variables

Names only — see `.env.example`; never commit values.

- **Required**: `CONTENTFUL_SPACE`, `CONTENTFUL_TOKEN`, `REDIS_URL`, `KONA_API_URL`, `API_TOKEN`.
  ⚠️ `API_TOKEN` is needed in **two** places: the build env (for the icons fetch) and the
  **Worker's dashboard secrets** — without the latter every widget 401s and collapses on the site.
  It must match the api's.
- **Build credential**: `WEBAWESOME_NPM_TOKEN` — Web Awesome Pro npm auth, read by `.npmrc` at
  install time (not in `.env`). Set it in your shell and in the workflow, or the install fails.
- **`IMAGES_URL`, required everywhere including locally** — the host Cloudflare Images serves
  transformations from. Building any image without it raises `ImageHelpers::ImagesUrlMissing`.
  Point your local `.env` at the real zone and `middleman server` renders what production serves.
  It deliberately has **no fallback**: it used to resize via Contentful when unset, which looked
  perfect while draining Contentful's bandwidth, so the only thing the fallback reliably did was
  hide a broken deploy. Don't reintroduce one.
- **`IMAGE_HOST`, required everywhere including locally** — bare hostname of the R2 image mirror.
  ⚠️ Not optional and not a rollback switch; ⚠️ setting it asserts the mirror is populated. Full
  contract in the root [`CLAUDE.md`](../CLAUDE.md).
- **Optional**: `TURNSTILE_SITE_KEY` (pair with the api's `TURNSTILE_SECRET`, both or neither).
  `TIME_ZONE` — the IANA zone the publish dates are reckoned in, read by the publish-date
  controller for "published today", the clock-vs-calendar icon and the "New" badge. ⚠️ Unset,
  each reader gets their *own* browser timezone, so a post published at 9pm Pacific reads as "not
  today" in Europe immediately; it must be set in the build env to reach production.
  `READING_TIME_WPM` (default 200) and `DEBUG_EVENT_DATE` (local-only: shifts every imported
  event's date, for exercising the race-day states).
  There is deliberately **no** var for the OG cards — the card URL is same-origin, built from
  `root_url`. One consequence: a **local** build emits `http://localhost:4567/…og.png`, which
  `middleman server` won't render because it doesn't run the Worker. Use `wrangler dev` to
  exercise a real card.

## Conventions & gates

**Before committing** (non-negotiable): `bundle exec rake test` + `npm test` + `npm run check`
pass → `bundle exec rubocop` + `npm run lint:js` + `npm run lint:scss` + `npm run format:check`
clean →
`bundle exec rake build:verbose` succeeds. ⚠️ **`rake build` does NOT run tests**, and it is the
only gate that exercises the templates — a broken partial passes every other check and fails the
deploy. ⚠️ Run it with the CI env shape (`READING_TIME_WPM="" TIME_ZONE=""`): an unset GitHub
Actions **variable** arrives as an empty string, not an absent one, so a local `.env` that simply
omits a key tests a different code path than production. Follow `.editorconfig`.

`.github/workflows/web.yml`'s `checks` job runs these same gates on every push to `main` and every
PR, and **gates the deploy**. It runs **`bundle exec rspec`** directly, not `rake test`: booting
the Rakefile introspects the live Contentful schema, whereas rspec loads only the specs and runs
credential-free.

**`dependencies` vs `devDependencies`**: the CI deploy job installs with **`npm ci --omit=dev`**,
so anything the build or deploy needs must be a `dependency` — `esbuild`, the JS-bundle imports
(`@hotwired/*`, `@web.awesome.me/*`), `pagefind`, `wrangler`, and the card renderer's `satori` +
`@resvg/resvg-wasm`. Test/lint tools stay `devDependencies`.

⚠️ **`satori` and `@resvg/resvg-wasm` are the two dependencies CI cannot vet.** Nothing in the test
suite executes a render, and a major bump can quietly change the wasm-init contract or the card's
text metrics. Render a card in `wrangler dev` (**The two local loops**) and look at it before
merging a Dependabot PR.

**Widget markup**: editing a placeholder partial means editing the matching `api/` view too (root
`CLAUDE.md`).

### JavaScript tests

`npm test` runs **two Vitest projects** (`test.projects` in `vitest.config.mts`), because the two
bodies of JS need mutually incompatible runtimes — workerd has no `document`, jsdom has no
`caches.default` or `request.cf`:

| Project | Covers | Runtime | Files |
|---|---|---|---|
| `worker` | `src/*.ts` | `workerd`, via `@cloudflare/vitest-pool-workers` | `test/*.test.ts` |
| `browser` | `source/javascripts/**` | `jsdom` | `test/browser/**/*.test.js` |

⚠️ **The two `include` globs are kept apart by FILE EXTENSION, not by directory.** A `.test.ts`
file anywhere under `test/` — `test/browser/` included — is claimed by the **worker** project and
dies on the first `document` reference, for reasons that look nothing like the cause. Browser tests
are `.js`.

⚠️ **The OG card render is deliberately NOT covered, and `src/og-render.ts` must never be imported
from `test/`.** The pool's module-fallback loader force-types only `.wasm`; every other extension
is read as UTF-8 and parsed as JS, so that file's `.ttf` and `.png` Data modules die there with a
syntax error that looks nothing like its cause. That's why `handleOg` takes its renderer as an
injected `RenderCard` parameter and reaches the real one through a dynamic `import()` —
`test/og.test.ts` covers the whole route contract with the render stubbed, and
`test/index.test.ts`'s routing case is a `POST` precisely because a 405 is answered before the
import. Verify renders with `npx wrangler dev` — see **The two local loops**.

Conventions for `test/browser/`:

- `helpers.js` — `mount(identifier, ControllerClass, html[, prepare])` writes the markup, starts a
  Stimulus application around it, and returns `{ application, element, controller }`. The markup
  lands **before** `start()`, so `connect()` has already run when it resolves; use `prepare` for
  state connect will read. Elements added *after* mounting arrive via MutationObserver — `await
  flushDom()`. ⚠️ `mount()` writes `document.body`, so append test-only elements **after** it.
- `stubProperty(navigator, 'share', …)` for the read-only getters `vi.stubGlobal` can't touch.
- `setup.js` polyfills what jsdom omits (`matchMedia`, `requestIdleCallback`, `Element#scrollTo`)
  and resets DOM, `window`, and mock state per test.
- **Module-scoped state needs `vi.resetModules()` + a dynamic import per test.** Four modules have
  it: the live-update clock, pagefind's `loading` / `idleScheduled`, and analytics'
  `searchTrackingReady`. Without the reset, tests silently depend on their predecessors.
- The **custom element registry** belongs to the jsdom instance, not the module registry —
  `vi.resetModules()` can't clear it, and re-`define()`ing a name throws. Guard with
  `customElements.get(name)`, or order the tests so the not-yet-defined case runs first.
- `clearMocks: true` is set: `vi.mock()` factories are hoisted and run once per file, so their
  `vi.fn()`s are shared by every test in it.
- `registration.test.js` reads `index.js` as **source** (importing it would pull in the whole Web
  Awesome theme) and asserts every controller is imported *and* registered under the kebab-case of
  its filename — the failure mode being an inert `data-controller` attribute with nothing logged.
  It also fails when a controller or lib module has no test file.

### Permissions

- Autonomous: read files, single-file `rspec`, lint/format, local `middleman`.
- Ask first: `git push`/commit, `rake redis:clear`, package installs, anything that triggers a
  deploy or build hook.
