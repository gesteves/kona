# utilities/contentful — content migrations & the taxonomy toolkit

Node scripts that read and write content **in Contentful itself**, as opposed to the render-time
transforms in `web/lib/helpers/`. It lives under `utilities/` so that running or editing anything
here never triggers a build, a deploy, or an edge-cache purge (root [`CLAUDE.md`](../../CLAUDE.md),
which also has the comment-style conventions).

Two kinds of thing live here, using **different Contentful APIs**:

- **One-off content migrations** — rewrite entry fields with `contentful-migration`
  (`runMigration` + `transformEntries`). Some are *spent*, kept only as templates.
- **The taxonomy toolkit** — manages the org's SKOS taxonomy through the `contentful-management`
  **plain client** at the organization level. These are **idempotent, re-runnable** maintenance
  tools that reconcile Contentful to one source-of-truth file.

⚠️ [`README.md`](README.md) documents per-script usage, flags, and the full taxonomy cutover
**runbook** — **keep it updated** whenever a script is added, changed, or removed.

## Commands

Run everything from this directory (`npm install` once first). The npm scripts load this
directory's `.env` via `node --env-file` — copy `.env.example` and fill in:

- `CONTENTFUL_SPACE` (same value as `web/.env`).
- `CONTENTFUL_MANAGEMENT_TOKEN` — a CMA token; the web app's *delivery* token cannot write.
- `CONTENTFUL_ORGANIZATION_ID` — **taxonomy scripts only**, since concepts and schemes are
  org-level.

The management token lives here, not in `web/.env`, because the build never uses it. No
`contentful login` needed. `taxonomy:preview` needs no credentials at all.

## The taxonomy

The blog's tags are a Contentful **SKOS taxonomy**: concept **schemes** + **concepts**, both
**organization-level**. Consequences worth internalizing:

- **Writes** go through the CMA plain client at the org — `client.concept.*`,
  `client.conceptScheme.*` (see `createPlainClient` / `getExistingConcepts` in `lib/taxonomy.js`).
  Edits are **JSON Patch** ops against the concept's `sys.version`. Concept listing is
  cursor-paginated (`page.pages.next`), not skip/limit.
- **The apps read it a different way** — don't confuse the two. GraphQL
  `contentfulMetadata.concepts` returns only concept **ids**, which the apps join to names and
  hierarchy from the **delivery/preview REST** `…/taxonomy/concepts` endpoint (`web` over the
  preview host, `api` over the cdn host). Nothing the apps use can *write* the taxonomy.

### Single source of truth: `scripts/lib/taxonomy.js`

Every taxonomy script reads from it, so what you preview is exactly what runs:

- `SCHEMES` — the two schemes: `sports` and `topics`.
- `CONCEPTS` — `{ id, name, scheme, broader, altLabels, description }`. `broader` is a single
  parent id; multi-level chains allowed. `description` is Markdown.
- `ASSIGNMENTS` — `article slug → { sports: <most-specific id|null>, topics: [ids] }`. The map
  stores only the **leaf**; scripts expand each up its `broader` chain and write the **full path**.
- Helpers plus the CMA client/env plumbing.

**To change the taxonomy — add a concept, rename one, edit copy, reassign an article, add the
planned Locations scheme — edit this file and re-run the relevant idempotent script.** Always
`npm run taxonomy:preview` first: read-only, no credentials, and it cross-checks coverage against
`../../web/data/articles.json`.

### Design rules

- A **scheme** is an orthogonal, universal, browse-by-it axis. Sports and a future Locations scheme
  qualify; Tech and Training are *values*, so they're concepts inside Topics. Adding Locations
  later is a third scheme plus a race→location map, with no rework of Sports/Topics.
- Articles carry their **full concept path** per scheme, not just the leaf, so chips, archives, and
  breadcrumbs reflect every level.
- ⚠️ prefLabels **"Race Reports"** and **"Reviews"** must stay **exactly** those strings — `web`'s
  `share_helpers` matches them, and renaming breaks feed/OG/JSON-LD.
- The private **`short`** metadata tag has **no concept** (it's invisible to the CDA); assign and
  unassign must skip tags without a concept, or they 422.
- Descriptions are **Markdown**. They may contain inline HTML and Markdown links, but links must be
  **relative** (`/tagged/…`) — never hardcode the production host.

### Gotchas

- ⚠️ **`taxonomy:describe` reconciles EVERY concept**, so it will silently **overwrite descriptions
  and altLabels edited directly in the Contentful UI**. Once you edit copy in the web UI,
  `lib/taxonomy.js` has drifted and is no longer the source of truth — sync those edits back before
  re-running, or use the scoped `taxonomy:describe-events`, which patches only the event concepts'
  `/definition`. Prefer scoped scripts when you only mean to change a subset.
- ⚠️ **No legacy fallback anywhere.** The apps require the taxonomy at build/request time, so a
  structural change is a **paused-builds cutover** (backup → unassign → delete → create → validate
  → assign → describe → redirects → deploy → resume builds → api backfill), not a rolling one. The
  ordered runbook is in [`README.md`](README.md).
- **Teardown reuses ids**: `taxonomy:delete` removes all org schemes and concepts deepest-first and
  **refuses while any entry still links a concept** — run `taxonomy:unassign` first. `create` then
  recreates with the same ids.
- **URL churn**: nesting concepts moves `/tagged/*` archive URLs. Handle it with Contentful
  `redirect` **entries** (`taxonomy:redirects`), whose old paths are read from `web/data/tags.json`
  — ⚠️ run it **before** re-importing web data. Never hardcode redirects.
- **Redis cache**: `web` caches the delivery taxonomy for ~1h. After a taxonomy write, run
  `rake redis:clear` in `web/` before expecting a fresh import to reflect it.
- **api needs no changes** for taxonomy edits — it only resolves concept id→name. After
  re-assignment, run `standard_site:backfill` so its records pick up the new concept-name tags.

## Script inventory

**Taxonomy toolkit** — idempotent and re-runnable; all read `lib/taxonomy.js`:

| npm script | What it does |
|---|---|
| `taxonomy:preview` | read-only render + validate the design (no creds, no writes) |
| `taxonomy:create` | create/reconcile both schemes and all concepts (**prefLabel + broader only**) |
| `taxonomy:describe` | write **every** concept's `definition` + `altLabels` ⚠️ overwrites UI edits |
| `taxonomy:describe-events` | scoped: only the event concepts' `/definition` |
| `taxonomy:assign` / `taxonomy:unassign` | set / clear each article's `metadata.concepts` |
| `taxonomy:validate-article` / `:revert` | add / remove the two scheme validations on `article` |
| `taxonomy:delete` | teardown: delete all org schemes + concepts (unassign first) |
| `taxonomy:redirects` | upsert `redirect` entries for moved `/tagged/*` URLs |

**Utility:** `backup` wraps `space export` to a timestamped JSON. Run it before any destructive
migration.

**Spent one-off transforms** — already run against production; kept as templates, not to be re-run:
`fix:degrees`, `fix:paces`, and `migrate:headings` (+ `:revert`, backed by `lib/shift-headings.js`).

## Conventions for new migrations

Use `scripts/fix-degrees.js` and `scripts/bump-heading-levels.js` as templates.

- **Skip unchanged entries** — return `undefined` from `transformEntryForLocale` when nothing
  changed. Republishing bumps `sys.publishedAt`, which feeds the sitemap `<lastmod>` and the Atom
  feed, and fires the Contentful webhooks (→ PDS re-sync, re-embedding, and a site rebuild).
- **`shouldPublish: 'preserve'`** — published entries stay published, drafts stay drafts.
- Support `DRY_RUN` / `ENTRY_ID` / `CONTENTFUL_ENVIRONMENT` in every script.
- ⚠️ **Migrations are hard to revert.** Dry-run first, prefer a sandbox environment, take an
  `npm run backup` export before touching master, and pair destructive transforms with an inverse
  script. Contentful's per-entry snapshots are the last-resort fallback.
- If a migration pairs with template/CSS changes in `web/`, mind the rollout order: content and
  code can't ship atomically, so usually deploy the code first, then migrate.

## Content model notes

- `article` holds **both** Articles and Shorts (Markdown in `intro` + `body`; a Short has `intro`
  only — see `set_entry_type` in `web/lib/data/contentful.rb`).
- `page` has Markdown in `body` only.
- `redirect` is its own content type. `event` is too, but the taxonomy scripts don't touch it —
  `ASSIGNMENTS` is a static hand-reviewed map, so `EVENT_CONTENT_TYPE` in `lib/taxonomy.js` is an
  unused export and safe to drop.
