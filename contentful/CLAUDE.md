# contentful/ — one-off content migrations

Scripts that rewrite content **in Contentful itself** (as opposed to render-time
transforms in `web/lib/helpers/`), using the `contentful-migration` library
programmatically (`runMigration` + `transformEntries`). This directory lives outside
`web/` on purpose: Netlify only builds when files under its `base = "web"` (or the root
`netlify.toml`) change, so editing migrations here never triggers a deploy.

⚠️ [`README.md`](README.md) documents how to use each script — **keep it updated
whenever a script is added, modified, or removed** (new npm script → new README section;
behavior/flag changes → update the matching section; deletions → remove it).

## Commands

Per-script usage, setup, and the `DRY_RUN` / `ENTRY_ID` / `CONTENTFUL_ENVIRONMENT`
options are documented in [`README.md`](README.md) — run everything from this directory
(`npm install` once first). The npm scripts load this directory's `.env` via
`node --env-file` — copy `.env.example` and fill in `CONTENTFUL_SPACE` (same value as
`web/.env`) and `CONTENTFUL_MANAGEMENT_TOKEN` (a CMA token; the web app's delivery token
won't work). No `contentful login` needed. The management token lives here, not in
`web/.env`, because the build never uses it.

## Conventions for new migrations

See `scripts/fix-degrees.js` and `scripts/bump-heading-levels.js` as templates.

- **Skip unchanged entries** — return `undefined` from `transformEntryForLocale` when
  nothing changed, so untouched entries aren't rewritten or republished. Republishing
  bumps `sys.publishedAt`, which feeds the web sitemap `<lastmod>`, the Atom feed, and
  fires the Contentful webhooks (→ api PDS re-sync, re-embedding, Netlify builds).
- **`shouldPublish: 'preserve'`** — published entries stay published, drafts stay drafts.
- Support `DRY_RUN` / `ENTRY_ID` / `CONTENTFUL_ENVIRONMENT` (above) in every script.
- ⚠️ **Migrations are hard to revert** — dry-run first, prefer testing on a sandbox
  environment, take a `contentful space export` backup before touching master, and pair
  destructive transforms with an inverse script. Contentful's per-entry version history
  (snapshots) is the last-resort fallback.
- If a migration pairs with template/CSS changes in `web/`, mind the rollout order:
  content and code can't ship atomically (the site rebuilds from Contentful at build
  time) — usually deploy the code first, then migrate.

## Content model notes

- `article` holds **both** Articles and Shorts (Markdown in `intro` + `body`; a Short is
  an entry with `intro` only — see `set_entry_type` in `web/lib/data/contentful.rb`).
- `page` has Markdown in `body` only (no `intro`).
