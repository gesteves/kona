# web/ — Kona static site

The Middleman 4 static site generator (Ruby 4.0.6). It builds a blog whose content comes from
**Contentful**, and it deploys to the **`kona-web` Cloudflare Worker**, which serves the build as
static assets. esbuild makes a bundle of the JavaScript (Stimulus and Turbo) and of the **Web
Awesome Pro** theme CSS, through the external pipeline of Middleman. Sass compiles the other
stylesheets. The UI components come from Web Awesome Pro, and
`source/javascripts/stimulus/index.js` imports them.

The weather data, the activity data, and the Whoop data are in `api/`, and the page loads them at
run time. Refer to the root [`CLAUDE.md`](../CLAUDE.md) for the contract between web and api before
you change the markup of a widget, and for the rules for a comment that this app obeys.

⚠️ **Write each comment, all the inline documentation, and each change to a `CLAUDE.md` file in
ASD-STE100 Simplified Technical English, and keep it short.** The root
[`CLAUDE.md`](../CLAUDE.md) has the full rule.

## Commands

Run `nvm use` before each `npm` command. There is one native dependency: **libvips**
(`brew install vips`). The blurhash placeholders render through `ruby-vips`. That gem is here and
not ImageMagick, because Cloudflare Workers Builds already has libvips.

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

Neither one gives the full site. Select one from the files that you edit.

| | `middleman` (:4567) | `wrangler dev` (:8787) |
|---|---|---|
| Serves | `source/`, re-rendered per request | `build/`, as deployed |
| Reflects an edit | on reload | only after a rebuild |
| `/widgets/*`, `POST /api/contact` | ✓ via `lib/utils/dev_api_proxy.rb` | ✓ the real Worker |
| `/pa/*`, OG cards | ✗ | ✓ |

Thus you can develop the **markup** of a widget on :4567. Only three things still need :8787: the
Worker code itself, the Plausible proxy, and the cards. The root [`CLAUDE.md`](../CLAUDE.md) gives
the proxy and `overmind start`.

Thus for the Worker code, the widget markup, and the OG cards, run `rake build:fast`, then
`npx wrangler dev`, and run `build:fast` again after each change to the source. `build:fast` does
not run `import`, and `rake build` and `build:verbose` always run it. That import is approximately
2s of a warm build of approximately 9s, but it writes `data/` again and it is the one part of this
loop that needs a network. Without it, the build works offline, and neither a failure in
`import:icons`, which raises on purpose, nor a cold start of the fly machine of the api, with its
six `/api/icons` requests in sequence, can stop the build.

`wrangler dev` needs only `.env`: with no `.dev.vars` file, wrangler reads `.env` and `.env.local`
in this directory. Thus `KONA_API_URL` and `API_TOKEN` are available, and each widget on :8787 goes
to the api that the file names. Set `KONA_API_URL` to a local `api/bin/dev` to work on both apps at
the same time.

### Import subtasks

`rake import` runs all five at the same time. `import:content` reads Contentful. `import:icons`
posts the list in `data/font_awesome.yml` to the `/api/icons` of the api and writes
`data/icons.json`. `import:standard_site` gets the DID and the publication URI from the api.
`import:related` gets the order of the related articles, which the api makes from a BM25 index of
the article text, and writes it to `data/related.json`. Each article uses that order for its "You May Also Like"
section. `import:schema` writes the Contentful GraphQL schema to
`lib/data/graphql/contentful_schema.json`, which the data layer reads at its start. Git ignores that
file, and with no file the data layer reads the live schema. There is also `rake redis:clear`.

⚠️ A failure in `import:icons` **raises**. Each page needs the icons, thus the build stops with a
message and it does not send pages with an icon absent. `import:standard_site` and `import:related`
are different: they write nothing on a failure, and the markup that they supply is then absent.

⚠️ In `data/related.json`, a **key** says that the api ranked that entry. Thus
`report_related_coverage` counts the keys and never the lists that have an entry. The api makes its
index from the same Contentful read that gives it the article list, thus each published entry gets a
key and no external call can leave a gap. It also always fills a list to the number that the caller
asks for, thus an empty list means that the corpus itself is empty. A gap in either number means that
the api could not read Contentful. Run `rake related:audit` there.

## Key locations

- `config.rb` — the Middleman configuration and the proxy setup. `Rakefile` — the Redis start and
  the task loader.
- `lib/data/` — the clients for the build: `contentful.rb` and `graphql/`.
- `lib/tasks/` — `import`, `build`, `test`, and `redis`.
- `lib/helpers/` — the helper modules. `config.rb` requires each module in that directory and
  registers it.
- `source/layouts/`, `source/partials/` with `placeholders/`, `source/javascripts/stimulus/`, and
  `source/stylesheets/`.
- `src/` and `wrangler.jsonc` — the Cloudflare Worker, which **is** the host of the site.
- `data/font_awesome.yml` — the **list of the icons**. Add each new icon here, below the correct
  family and style, for example `classic.light`, before `icon_svg` can use it. That is an edit to
  one yml file on the web side, and the api finds the icon when it is necessary.

### The size of a listing page

The blog index and each tag archive render **every** entry, and no page has pagination. That is
good for a crawler: each post is two clicks from the home page, there is no `rel=prev/next` to get
incorrect, and there is no paginated-canonical trap. The cost is the size of the page.

⚠️ **Known boundary, measured at 58 entries: `/blog/` is approximately 580KB of HTML.** The cover
image of a card is approximately 20% of that, because each one holds six srcset candidates and an
inline blurhash data URI. A Short also renders its full body in the list, because its intro *is* the
post. This is acceptable at 58 entries and it will not be at 300. When it becomes a problem, the
first step is to render the inline blurhash for the first cards only, and pagination is the last
step, not the first.

### Render-blocking budget

**Only `stylesheets/site.css` can stop the first render.** `_head.html.erb` has an order that makes
it the one stylesheet that stops the render.

- **The CSS and the JavaScript of Pagefind are not in the head.**
  `javascripts/stimulus/lib/pagefind.js` adds them: an early load at the first idle moment after
  `load`, an early load when the pointer or the focus goes to a Search button, and a call that
  `search#open` waits for. ⚠️ The code puts the stylesheet **before the first
  `<link rel="stylesheet">` in the page**, and never at the end.
  `stylesheets/components/_pagefind.scss` changes the `--pf-*` variables of Pagefind for the dark
  mode, from a `:root` block with no layer, and that block wins only because it is later in the
  *source* order. At the end, the modal is light at night, for all time, and it gives no message.
- The Web Awesome theme (`/javascripts/site.css`) still stops the render, and it does not need to,
  because it has custom-property definitions only. ⚠️ **Do not use `media="print" onload=…` to
  change that.** Turbo puts the **`outerHTML`** of each element with `data-turbo-track="reload"`
  into its signature of the tracked elements. Thus a change to an attribute at run time makes each
  navigation a full page load, and that stops the view transitions with no message. The removal of
  `data-turbo-track` does not help: Turbo then adds a second copy of the link at each navigation.
  **Never change an attribute of a tracked element in the head.** Two solutions work: put the CSS in
  a `<style>` element, or add the `<link>` from JavaScript, as `lib/pagefind.js` does.
- The page loads each woff2 face above the fold early. `crossorigin` is necessary, and this includes
  a same-origin URL, or the browser gets each font two times. Each URL must come from
  `asset_path(:fonts, …)`, because each font name has a hash.

### Open Graph cards

A page with no cover image gets an `og:image` that **the Worker of this app renders when it is
necessary**: `src/og.ts` is the route and `src/og-render.ts` is the card. `run_worker_first` takes
`/og.png` **and** `/*/og.png`. `generate_open_graph_image_url` makes
`<root_url><page path>og.png?v=<OG_TEMPLATE_VERSION>-<published_version>`. A page with a cover image
uses `open_graph_image_url`, which gives a Cloudflare Images URL.

- **The path of the card names the page.** That is the reason for the two `run_worker_first`
  entries: a rule has `^…$` at its two ends and each `*` becomes `.*`. It is also the reason that
  the handler has no `?path=` parameter to check. The handler removes the **file name** only and it
  keeps the slash at the end: the asset from the build is `/post/index.html`, and
  `html_handling: "auto-trailing-slash"` answers a `/post` with no slash with a redirect. The check
  for a 200 in the handler reads that redirect as a page that is absent.
- **The title comes from the `og:title` of the page, through the `ASSETS` binding.** The Worker does
  not get it over HTTP. Thus the renderer can draw only a title that is in the deployment, and no
  text from a caller is in this path.
- **The page names its own `v` in its og:image, and the Worker renders that version only.** A
  request with another `v`, or with none, gets a 301 to the declared one, and a page whose og:image
  is not this card gets a 404. Thus each page has one card in the cache, whatever a caller sends.
- **The content addresses each article card**: a new publish increases `published_version` and gives
  a new URL. ⚠️ Increase `OG_TEMPLATE_VERSION` after you change `og-render.ts`,
  `src/assets/logo.png`, or the font. If you do not, the old cards, which the cache holds for a
  year, continue to appear.
- ⚠️ **`textWrap: 'balance'` goes on a title of MORE THAN ONE WORD only**, and `cardElement`
  guards it. satori **halves** the width of a title that has no break opportunity: it lays out for
  two lines, and one word cannot make two. "Blog" then measures 101px in place of its true 168px.
  `backgroundClip: 'text'` paints the gradient through that box, thus the word is **cut in the
  middle of a glyph** and only a listing page shows it, because an article title has many words.
  ⚠️ Never set `textWrap` to `undefined` to turn it off: the CSS parser of satori reads that value
  and raises. Spread the property, as the code does.
- ⚠️ **A card of a listing page does NOT change by itself.** The blog index, each tag archive, and
  the home page are not Contentful entries. Thus `v` is `OG_TEMPLATE_VERSION` only, and the URL
  never changes. Today that is 43 of the 73 pages with a card. Their `og:title` comes from
  `data.site.meta_title` or from a tag name. The `Cache-Tag: site` purge of the deploy is what makes
  them new, and that is why the zone still tags the card paths, on purpose (refer to the root
  `CLAUDE.md`).
- ⚠️ **This needs the Workers Paid plan**: a render takes approximately 100 ms of CPU, and the Free
  plan permits 10 ms.
- ⚠️ **`wrangler dev` covers a render, and the test suite does not.** Refer to **The two local
  loops** and to **JavaScript tests**.
- `src/assets/` holds the font and the logo of the card, as Data modules. That is the reason for the
  `rules` entry in `wrangler.jsonc`.

### `_headers` and `_redirects`

The build makes these from `source/headers` and `source/redirects.erb`, and it then renames them. A
source file with an underscore at the start of its name is a partial, and the build does not write
it.

- ⚠️ In `_headers`, no two rules can set the same header for paths that overlap. On Cloudflare, two
  rules that match join the headers with the same name, with a comma between the values.
- ⚠️ **The ORDER of the rules in `_redirects` is important.** Cloudflare permits 2,000 "static"
  rules but only 100 "dynamic" rules, and its `canCreateStaticRule` flag **becomes false at the
  first rule whose source has a `*` or a `:placeholder`**. Each rule after that one counts as
  dynamic, and this includes each exact match. Thus `redirects.erb` writes each exact-match redirect
  **before** each redirect with a splat. With a splat early, the deploy fails with `code: 100324`
  when the file becomes longer than approximately 100 lines. Do not put a `*` rule or a `:name` rule
  above the static block.
- ⚠️ **Cloudflare refuses an absolute URL as a *source***, and it refuses a **200-status proxy
  rewrite to an absolute URL**. Each of the two stops the deploy with only `code: 100324`.
  `redirects.erb` removes them, because a person writes each redirect in Contentful and an incorrect
  one would then stop the deploy. Put a cross-domain redirect in a zone rule of Cloudflare, or in a
  Bulk Redirect.

### The Worker

`wrangler.jsonc` and `src/`: the Worker serves `build/` as static assets. It also has the routes of
the widget proxy, of the Plausible proxy (`src/plausible.ts`, and not a rewrite in `_redirects`), of
the contact form, and of the OG cards.

⚠️ **`run_worker_first` is a list of the paths that the Worker answers, and it answers no other
path.** It has each dynamic route: `/widgets/*`, `/api/contact`, `/pa/*`, `/og.png`, and
`/*/og.png`. Each other path — each HTML page, each asset with a fingerprint, the sitemap, the
feeds, `/.well-known/*`, and each 404 — comes from the static asset layer, and it costs no Worker
call. Each route in the list needs the Worker, because it has **no asset**. When you add a dynamic
route, add its path here, and note that a Cloudflare glob **goes past a `/`**.

⚠️ A new entry also needs a matching **exclusion in the edge-TTL Cache Rule of the zone** (refer to
the root `CLAUDE.md`). The OG cards are the exception: the `not path contains "."` part of that rule
already excludes them. That is why the OG route has an extension. Do not give it a name with no
extension until you add the exclusion.

⚠️ The types of the tests are separate from the types of the production code. `tsconfig.test.json`
covers test/** only, it loads `@cloudflare/workers-types`, and it removes the `dom` lib from the
parent configuration, because the `CacheStorage` of lib.dom has no `caches.default`. `tsconfig.json`
covers src only, with `types: []` and the declarations in `env.d.ts`. The two must never be in one
compile.

⚠️ Those two configurations together cover `src/` and `test/*.ts`, and nothing else. **ESLint
(`eslint.config.mjs`) covers the other files**: `source/javascripts/**` and `test/browser/**`, which
no typechecker reads. It does *not* read `src/**/*.ts`, on purpose. That needs typescript-eslint,
whose TypeScript peer dependency is still `<6.1.0`, and this project uses TypeScript 7. Its rules
that use the types call the API of the TypeScript compiler, thus a forced peer version would not
work, and it is more than unsupported. Read this again when typescript-eslint accepts TypeScript 7.
ESLint has **no format rule** on (a check gave 0 of 64), thus Prettier alone controls the layout and
`eslint-config-prettier` is not necessary.

⚠️ **The pool configuration is `vitest.config.mts`, and not `.ts`.** The pool 0.18 is ESM only, and
with no `"type": "module"` in `package.json`, Vite loads a `.ts` configuration as CJS and the import
fails. `test/helpers.ts` has its own code for the outbound fetch mock (`interceptFetch`), because
the same release removed the `fetchMock` of the pool.

## Environment variables

The names only. Refer to `.env.example`, and never put a value in the repo.

- **Necessary**: `CONTENTFUL_SPACE`, `CONTENTFUL_TOKEN`, `REDIS_URL`, `KONA_API_URL`, and
  `API_TOKEN`. ⚠️ `API_TOKEN` must be in **two** places: the build environment, for the icons fetch,
  and the **secrets of the Worker in the dashboard**. Without the second one, each widget gets a 401
  and goes away on the site. It must be the same as the token of the api.
- **A build credential**: `WEBAWESOME_NPM_TOKEN`, the npm authentication of Web Awesome Pro.
  `.npmrc` reads it at the install, and it is not in `.env`. Set it in your shell and in the
  workflow, or the install fails.
- **`IMAGES_URL`. Each environment needs it, and this includes your own machine.** It is the host
  that Cloudflare Images serves each transformation from. A build of an image without it raises
  `ImageHelpers::ImagesUrlMissing`. Set it in your local `.env` to the true zone, and
  `middleman server` then renders what production renders. It has **no fallback**, on purpose: the
  code resized with Contentful when this var had no value, which looked correct and which used the
  bandwidth of Contentful. Thus the only dependable result of that fallback was a broken deploy that
  nobody saw. Do not add a fallback again.
- **`IMAGE_HOST`. Each environment needs it, and this includes your own machine.** It is the host
  name of the R2 image mirror, with no scheme. ⚠️ It is not optional and it is not a way to go back.
  ⚠️ A value in it says that the mirror is complete. The full contract is in the root
  [`CLAUDE.md`](../CLAUDE.md).
- **Optional**: `TURNSTILE_SITE_KEY`. Use it with the `TURNSTILE_SECRET` of the api: set both, or
  set neither.
  `TIME_ZONE` is the IANA zone of the publish dates. The publish-date controller reads it for
  "published today", for the clock icon or the calendar icon, and for the "New" badge. ⚠️ With no
  value, each reader gets their *own* browser timezone. Thus a post that a person publishes at 9pm
  Pacific reads as "not today" in Europe immediately. The build environment must have it, or it does
  not reach production.
  `READING_TIME_WPM` has a default of 200. `DEBUG_EVENT_DATE` is for your own machine only: it moves
  the date of each event from the import, to let you test the race-day states.
  There is **no** var for the OG cards, on purpose: the URL of a card is same-origin and comes from
  `root_url`. One result: a build on **your own machine** writes `http://localhost:4567/…og.png`,
  and `middleman server` does not render that, because it does not run the Worker. Use
  `wrangler dev` to see a true card.

## Conventions & gates

**Before each commit** (these are necessary): `bundle exec rake test`, `npm test`,
`npm run check`, and `npm run check:worker` pass. Then `bundle exec rubocop`, `npm run lint:js`,
`npm run lint:scss`, and `npm run format:check` are clean. Then `bundle exec rake build:verbose` is successful. ⚠️ **`rake
build` does NOT run the tests**, and it is the one check that renders the templates: a bad partial
passes each other check and then stops the deploy. ⚠️ Run it with the same environment as CI
(`READING_TIME_WPM="" TIME_ZONE=""`). A GitHub Actions **variable** with no value arrives as an
empty string, and not as an absent value. Thus a local `.env` that omits a key tests a different
path than production. Obey `.editorconfig`.

The `checks` job of `.github/workflows/web.yml` does these same checks at each push to `main` and at
each PR, and it **controls the deploy**. It runs **`bundle exec rspec`** directly, and not
`rake test`: the Rakefile loads the data layer, and rspec loads the specs only and needs no
credentials. After one `rake import`, the data layer reads the Contentful schema from
`lib/data/graphql/contentful_schema.json` and `rake test` needs no network either.

**`dependencies` against `devDependencies`**: the deploy job of CI installs with
**`npm ci --omit=dev`**. Thus each package that the build or the deploy needs must be a
`dependency`: `esbuild`, the imports of the JavaScript bundle (`@hotwired/*` and
`@web.awesome.me/*`), `pagefind`, `wrangler`, and the two packages of the card renderer, `satori`
and `@resvg/resvg-wasm`. Each test tool and each lint tool stays a `devDependency`.

**`npm run check:worker`** bundles the Worker with `wrangler deploy --dry-run`. It needs no
credentials, it uploads nothing, and it makes `build/` first, because wrangler reads
`assets.directory`. It is the **only** check that resolves the imports of `src/og-render.ts`: no
test can load that file, and `tsc` reads types and never bundles. The `checks` job of CI runs it.

⚠️ **That check bundles the card renderer, and it does not RENDER a card.** `satori` and
`@resvg/resvg-wasm` can bundle correctly and still change the wasm start contract or the text
measurements of the card, and give no message. Render a card in `wrangler dev` (refer to **The two
local loops**) and look at it before you merge a Dependabot PR.

⚠️ **`satori` stays below 0.33**, and `.github/dependabot.yml` has an `ignore` entry that keeps it
there. 0.33 made `harfbuzzjs` a dependency of each render, and the Worker cannot run that package:
its Emscripten loader reads `fs` and `self.location`, and it compiles the wasm from bytes, which the
runtime refuses. `nodejs_compat` and an alias make it bundle, but the render still stops at
`self.location`. Remove the ignore entry only after a card renders in `wrangler dev`.

**The markup of a widget**: an edit to a placeholder partial needs the same edit to the matching
view in `api/` (refer to the root `CLAUDE.md`).

### JavaScript tests

`npm test` runs **two Vitest projects** (`test.projects` in `vitest.config.mts`), because the two
groups of JavaScript need two different runtimes that cannot be one: workerd has no `document`, and
jsdom has no `caches.default` and no `request.cf`.

| Project | Covers | Runtime | Files |
|---|---|---|---|
| `worker` | `src/*.ts` | `workerd`, via `@cloudflare/vitest-pool-workers` | `test/*.test.ts` |
| `browser` | `source/javascripts/**` | `jsdom` | `test/browser/**/*.test.js` |

⚠️ **The FILE EXTENSION keeps the two `include` globs apart, and not the directory.** The **worker**
project takes each `.test.ts` file below `test/`, and this includes `test/browser/`. Such a file then
stops at its first `document`, with an error that does not show the cause. Each browser test is a
`.js` file.

⚠️ **No test covers the render of an OG card, on purpose, and no file in `test/` can import
`src/og-render.ts`.** The fallback module loader of the pool sets the type for `.wasm` only. It
reads each other extension as UTF-8 and parses it as JS. Thus the `.ttf` and `.png` Data modules of
that file give a syntax error that does not show the cause. That is why `handleOg` takes its
renderer as a `RenderCard` parameter and gets the true one through a dynamic `import()`.
`test/og.test.ts` covers the full contract of the route with a stub for the render, and the routing
example in `test/index.test.ts` uses a `POST`, because the code answers a 405 before that import.
Check a render with `npx wrangler dev`. Refer to **The two local loops**.

The rules for `test/browser/`:

- `helpers.js` — `mount(identifier, ControllerClass, html[, prepare])` writes the markup, starts a
  Stimulus application around it, and returns `{ application, element, controller }`. The markup
  goes into the document **before** `start()`, thus `connect()` already ran when the promise
  resolves. Use `prepare` for the state that connect reads. An element that the code adds *after*
  the mount comes through the MutationObserver: `await flushDom()` for such an element.
  ⚠️ `mount()` writes `document.body`, thus add each element for the test **after** it.
- Use `stubProperty(navigator, 'share', …)` for a read-only getter that `vi.stubGlobal` cannot
  change.
- `setup.js` adds the APIs that jsdom does not have (`matchMedia`, `requestIdleCallback`, and
  `Element#scrollTo`), and it sets the DOM, `window`, and the mock state back for each test.
- **State at the module level needs `vi.resetModules()` and a dynamic import in each test.** Four
  modules have such state: the clock of the live update, the `loading` and `idleScheduled` of
  pagefind, and the `searchTrackingReady` of the analytics. Without the reset, one test depends on
  the tests before it, and nothing shows that.
- The **custom element registry** belongs to the jsdom instance, and not to the module registry.
  `vi.resetModules()` cannot empty it, and a second `define()` of a name raises. Test with
  `customElements.get(name)`, or put the example for the name with no definition first.
- `clearMocks: true` is on: Vitest moves each `vi.mock()` factory to the top and runs it one time
  for each file, thus each test in that file shares its `vi.fn()` values.
- `registration.test.js` reads `index.js` as **text**, because an import would load the full Web
  Awesome theme. It checks that the file imports each controller *and* registers it under the
  kebab-case form of its file name. The failure without that check is a `data-controller` attribute
  that does nothing, and no log line. It also fails when a controller or a lib module has no test
  file.

### Permissions

- Do these without a question: read a file, run `rspec` on one file, run a lint or a format
  command, and run `middleman` on your own machine.
- Ask first for these: `git push` and a commit, `rake redis:clear`, an install of a package, and
  each action that starts a deploy or a build.
