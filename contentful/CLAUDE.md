# contentful/ — content migrations & the taxonomy toolkit

Node scripts that read and write content **in Contentful itself** (as opposed to render-time
transforms in `web/lib/helpers/`). This directory lives outside `web/` on purpose: the "Web"
deploy workflow is path-filtered on `web/**`, so running or editing scripts here never triggers
a deploy.

Two kinds of things live here, and they use **different Contentful APIs**:

- **One-off content migrations** — rewrite entry fields with the `contentful-migration` library
  (`runMigration` + `transformEntries`). Some are *spent* (already run against production, kept
  only as templates/reference — see `fix-degrees.js`, `bump-heading-levels.js`).
- **The taxonomy toolkit** — manages the org's SKOS taxonomy (tags) through the
  `contentful-management` **plain client** at the organization level. These are **idempotent,
  re-runnable maintenance tools**, not spent one-offs: they all read one source-of-truth file and
  reconcile Contentful to match.

⚠️ [`README.md`](README.md) documents per-script usage, flags, and the full taxonomy cutover
**runbook** — **keep it updated** whenever a script is added, changed, or removed (new npm script
→ new README section; behavior change → update the section; deletion → remove it).

## Commands

Per-script usage, setup, and the `DRY_RUN` / `ENTRY_ID` / `CONTENTFUL_ENVIRONMENT` options are in
[`README.md`](README.md). Run everything from this directory (`npm install` once first). The npm
scripts load this directory's `.env` via `node --env-file` — copy `.env.example` and fill in:

- `CONTENTFUL_SPACE` (same value as `web/.env`).
- `CONTENTFUL_MANAGEMENT_TOKEN` (a CMA token — the web app's *delivery* token cannot write).
- `CONTENTFUL_ORGANIZATION_ID` — **required by the taxonomy scripts only**, because concepts and
  schemes are org-level, not space-level (see below).

The management token lives here, not in `web/.env`, because the build never uses it. No
`contentful login` needed. `taxonomy:preview` needs no credentials at all (it's read-only over
local files).

## The taxonomy (the most important thing in here)

The blog's tags are a Contentful **SKOS taxonomy**: concept **schemes** + **concepts**, both
**organization-level** (not space-level). Consequences worth internalizing before touching it:

- **Writes** go through the CMA **plain client** at the org — `client.concept.*`,
  `client.conceptScheme.*` (see `createPlainClient` / `getExistingConcepts` in `lib/taxonomy.js`).
  Needs `CONTENTFUL_ORGANIZATION_ID` + a management token. Edits are **JSON Patch** ops
  (`{op:'add', path:'/definition', value:{'en-US': …}}`) against the concept's `sys.version`.
  Concept listing is cursor-paginated (`page.pages.next`), not skip/limit.
- The **apps read the taxonomy a different way** (don't confuse the two): GraphQL
  `contentfulMetadata.concepts` returns only concept **ids**, which the apps join to names +
  hierarchy fetched from the **delivery/preview REST** `…/taxonomy/concepts` endpoint (singular
  "taxonomy"). `web` reads it over the preview host with its CPA token; `api` over the cdn host
  with its CDA token. Nothing the apps use can *write* the taxonomy.

### Single source of truth: `scripts/lib/taxonomy.js`

It holds **everything** and every taxonomy script reads from it, so what you preview is exactly
what gets created/described/assigned:

- `SCHEMES` — the two schemes: `sports` and `topics`.
- `CONCEPTS` — every concept as `{ id, name, scheme, broader, altLabels, description }`
  (`broader` = parent id, single-parent; multi-level chains allowed). `description` is Markdown.
- `ASSIGNMENTS` — `article slug → { sports: <most-specific id|null>, topics: [ids] }`. The map
  stores only the **leaf**; scripts expand each up its `broader` chain (`resolveAssignment`) and
  write the **full path** to `metadata.concepts`.
- Helpers + the CMA client/env plumbing (`expandAncestors`, `conceptLink`, `readEnv`, …).

**To change the taxonomy — add a concept, rename one, edit copy, reassign an article, or add the
planned Locations scheme — edit this file and re-run the relevant idempotent script.** Always
`npm run taxonomy:preview` first (read-only, no creds, cross-checks coverage vs
`../web/data/articles.json`).

### Design rules (why it's shaped this way)

- A **scheme** is an orthogonal, universal, browse-by-it axis. Sports and a future **Locations**
  scheme qualify; Tech/Training are *values*, so they're concepts inside Topics, not schemes.
  Adding Locations later = a third scheme + a race→location map, no rework of Sports/Topics.
- Articles carry their **full concept path** per scheme (discipline + distance + race, + topics),
  not just the leaf — so chips, archives, and breadcrumbs reflect every level.
- prefLabels **"Race Reports"** and **"Reviews"** must stay **exactly** those strings — `web`
  `share_helpers` matches them; renaming breaks feed/OG/JSON-LD.
- The private **`short`** metadata tag has **no concept** (it's invisible to the CDA); assign /
  unassign must skip tags that have no concept, or they 422.
- Descriptions are **Markdown** (rendered on the archive page, stripped to plain text in meta
  tags). They may contain inline HTML (`<span data-imperial="…">`, `<i>`) and Markdown links —
  but links must be **relative** (`/tagged/…`). Never hardcode the production host (root
  [`CLAUDE.md`](../CLAUDE.md)).

### Gotchas learned the hard way

- **`taxonomy:describe` reconciles EVERY concept** from `lib/taxonomy.js`, so it will silently
  **overwrite descriptions/altLabels edited directly in the Contentful UI**. Once you edit copy
  in the web UI, `lib/taxonomy.js` has drifted and is no longer the source of truth. Before
  re-running `describe`, sync UI edits back into the file — or use a **scoped** script:
  `taxonomy:describe-events` patches only the 17 race/event concepts' `/definition` and touches
  nothing else. Prefer scoped scripts when you only mean to change a subset.
- **No legacy fallback anywhere**: the apps require the taxonomy at build/request time, so a
  structural change is a **paused-builds cutover** (backup → unassign → delete → create →
  validate → assign → describe → redirects → deploy → resume builds → api backfill), not a
  rolling one. The full ordered runbook is in [`README.md`](README.md).
- **Teardown reuses ids**: `taxonomy:delete` removes all org schemes + concepts (deepest-first)
  and **refuses while any entry still links a concept** — run `taxonomy:unassign` first;
  `taxonomy:create` then recreates with the same ids (ids are free once the old concepts are gone).
- **URL churn**: nesting concepts moves `/tagged/*` archive URLs. Handle via Contentful
  `redirect` **entries** (`taxonomy:redirects`), driven by the design + old paths read from
  `web/data/tags.json` (run it **before** re-importing web data) — never hardcode redirects.
- **Redis cache**: `web` caches the delivery taxonomy (`contentful:taxonomy:concepts:v1`, ~1h).
  After a taxonomy write, `rake redis:clear` in `web/` before expecting a fresh import to reflect it.
- **api needs no changes** for taxonomy edits — it only resolves concept id→name (scheme-agnostic).
  After re-assignment, run the standard.site `standard_site:backfill` so its records pick up the
  new concept-name tags (fingerprints change once).

## Script inventory

**Taxonomy toolkit** — idempotent, re-runnable; all read `lib/taxonomy.js`:

| npm script | what it does |
|---|---|
| `taxonomy:preview` | read-only render + validate the design (no creds, no writes) |
| `taxonomy:create` | create/reconcile both schemes + all concepts (**prefLabel + broader only**) |
| `taxonomy:describe` | write **every** concept's `definition` + `altLabels` ⚠ overwrites UI edits |
| `taxonomy:describe-events` | scoped: only the 17 event concepts' `/definition` (safe alongside UI edits) |
| `taxonomy:assign` / `taxonomy:unassign` | set / clear each article's `metadata.concepts` (full path) |
| `taxonomy:validate-article` / `:revert` | add / remove the two scheme validations on `article` |
| `taxonomy:delete` | teardown: delete all org schemes + concepts (unassign first) |
| `taxonomy:redirects` | upsert `redirect` entries for moved `/tagged/*` URLs |

**Utility:** `backup` — wraps `space export` to a timestamped JSON (self-loads `.env`); run before
any destructive migration.

**Spent one-off transforms** — already run against production; kept as **reference/templates** for
writing new migrations, not meant to be re-run:

- `fix:degrees` (`fix-degrees.js`) — replace `º` (U+00BA) with `°` (U+00B0) in body/intro.
- `fix:paces` (`fix-paces.js`) — drop the redundant `min` in `M:SS min/unit` paces
  (`5:25 min/km` → `5:25/km`) in body/intro; anchored on the time so bare `5 min/km` is untouched.
- `migrate:headings` (`bump-heading-levels.js`) + `migrate:headings:revert` — bump in-body
  heading levels for the entry-title H1 restructure. Backed by `lib/shift-headings.js`.

## Conventions for new migrations

See `scripts/fix-degrees.js` and `scripts/bump-heading-levels.js` as templates.

- **Skip unchanged entries** — return `undefined` from `transformEntryForLocale` when nothing
  changed, so untouched entries aren't rewritten or republished. Republishing bumps
  `sys.publishedAt`, which feeds the web sitemap `<lastmod>`, the Atom feed, and fires the
  Contentful webhooks (→ api PDS re-sync, re-embedding, and a site rebuild via
  `repository_dispatch`).
- **`shouldPublish: 'preserve'`** — published entries stay published, drafts stay drafts.
- Support `DRY_RUN` / `ENTRY_ID` / `CONTENTFUL_ENVIRONMENT` in every script. The taxonomy scripts
  additionally honor `DRY_RUN` for their CMA writes (`readEnv` centralizes this).
- ⚠️ **Migrations are hard to revert** — dry-run first, prefer testing on a sandbox environment,
  take a `npm run backup` export before touching master, and pair destructive transforms with an
  inverse script. Contentful's per-entry version history (snapshots) is the last-resort fallback.
- If a migration pairs with template/CSS changes in `web/`, mind the rollout order: content and
  code can't ship atomically (the site rebuilds from Contentful at build time) — usually deploy
  the code first, then migrate.

## Content model notes

- `article` holds **both** Articles and Shorts (Markdown in `intro` + `body`; a Short is an entry
  with `intro` only — see `set_entry_type` in `web/lib/data/contentful.rb`).
- `page` has Markdown in `body` only (no `intro`).
- `redirect` is its own content type; `taxonomy:redirects` creates/updates its entries. `event`
  is a content type too, but the taxonomy scripts don't touch it — `ASSIGNMENTS` is a static
  hand-reviewed map, so `EVENT_CONTENT_TYPE` in `lib/taxonomy.js` is now an **unused export**
  (a leftover from an earlier design that resolved race reports via the linked event; safe to drop).
