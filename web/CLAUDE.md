# web/ — Kona static site

The Middleman site, and the `kona-web` Cloudflare Worker that serves it. The root
[`CLAUDE.md`](../CLAUDE.md) has the contract between web and api. Read it before you change the
markup of a widget.

⚠️ **Write each comment, all the inline documentation, and each change to a `CLAUDE.md` file in
ASD-STE100 Simplified Technical English, and keep it short.** The root
[`CLAUDE.md`](../CLAUDE.md) has the full rule.

## Setup

Run `nvm use` before each `npm` command.

`WEBAWESOME_NPM_TOKEN` is the npm credential of Web Awesome Pro. `.npmrc` reads it at the install,
and npm does not read `.env`. Thus set it in your shell.

`.env.example` gives each other variable and its rules. Never put a value in the repo.

## The local loops

`middleman server` (:4567) renders `source/` at each request. It does not run the Worker, thus
`/pa/*` and the OG cards do not work there. For the Worker code, the Plausible proxy, and the
cards, run `rake build:fast`, then `npx wrangler dev` (:8787). `wrangler dev` serves `build/`, thus
run `build:fast` again after each change. `build:fast` does not run `import`, thus it needs no
network.

## Conventions & gates

**Before each commit** (these are necessary): `bundle exec rake test`, `npm test`,
`npm run check`, and `npm run check:worker` pass. Then `bundle exec rubocop`, `npm run lint:js`,
`npm run lint:scss`, and `npm run format:check` are clean. Then `bundle exec rake build:verbose` is successful. ⚠️ **`rake
build` does NOT run the tests**, and it is the one check that renders the templates: a bad partial
passes each other check and then stops the deploy. ⚠️ Run it with the same environment as CI
(`READING_TIME_WPM="" TIME_ZONE=""`). A GitHub Actions **variable** with no value arrives as an
empty string, and not as an absent value. Thus a local `.env` that omits a key tests a different
path than production. Obey `.editorconfig`.

**`dependencies` against `devDependencies`**: the deploy job of CI installs with
**`npm ci --omit=dev`**. Thus each package that the build or the deploy needs must be a
`dependency`. Each test tool and each lint tool stays a `devDependency`.

**The markup of a widget**: an edit to a placeholder partial needs the same edit to the matching
view in `api/` (refer to the root `CLAUDE.md`).

- ⚠️ **Only `stylesheets/site.css` can stop the first render.** Load each other stylesheet and each
  script with no block. `_head.html.erb` shows the methods and the Turbo trap of each one.
- ⚠️ **Add each new icon to `data/font_awesome.yml`**, below its family and style. `icon_svg` gives
  nil for an icon that is not there, thus the page shows no icon and gives no message.
- ⚠️ **A browser test of a module with state at the module level needs `vi.resetModules()` and a
  dynamic import in each test.** Without the reset, one test depends on the tests before it, and
  nothing shows that.
- **The blog index and each tag archive render every entry, and no page has pagination, on
  purpose.** Each post is then two clicks from the home page. When `/blog/` becomes too large,
  first render the inline blurhash for the first cards only. Pagination is the last step.

## Open Graph cards

A page with no cover image gets a card that the Worker renders (`src/og.ts`, `src/og-render.ts`).

- ⚠️ **This needs the Workers Paid plan**: a render takes approximately 100 ms of CPU, and the Free
  plan permits 10 ms.
- ⚠️ **No test can import `src/og-render.ts`.** `test/og.test.ts` gives the reason. `npm run
  check:worker` bundles the renderer, but it does not render a card. Thus `npx wrangler dev` is the
  only check of a render. Render a card there and look at it before you merge a Dependabot PR.
- ⚠️ **`satori` stays below 0.33.** `.github/dependabot.yml` gives the reason and holds the
  `ignore` entry.
- A listing page has no `published_version`, thus the `v` of its card holds a CRC32 of its
  `og:title` (`open_graph_card_url`).

## File names that the zone permits

`/build-id.txt` is the deploy gate: `web.yml` reads it until the edge serves the new build, then it
purges again.

- ⚠️ **Keep the name `build-id.txt`.** The scanner rule of the zone blocks the prefix `/deploy/` and
  the file names of secret material, across the full zone. `build-id` clears each of those families.

## The Markdown documents: `/.well-known/about.md` and the `index.md` of each post

- ⚠️ A new kind of markup in a body goes out as its text only. Add a step for it to
  `normalize_for_markdown`.
- ⚠️ **The front matter must be the first line of the file.** Thus each template is one ERB tag
  with no comment and no newline.

## Permissions

- Do these without a question: read a file, run `rspec` on one file, run a lint or a format
  command, and run `middleman` on your own machine.
- Ask first for these: `git push` and a commit, `rake redis:clear`, an install of a package, and
  each action that starts a deploy or a build.
