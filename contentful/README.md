# Contentful content migrations

One-off scripts that rewrite content **in Contentful itself**, run locally. This
directory lives outside `web/` so editing these scripts never triggers a site build.

## Setup (once)

```bash
cd contentful
npm install
cp .env.example .env   # fill in CONTENTFUL_SPACE + CONTENTFUL_MANAGEMENT_TOKEN
```

`CONTENTFUL_SPACE` is the same value as `web/.env`'s. `CONTENTFUL_MANAGEMENT_TOKEN` is a
personal CMA token (the web app's delivery token won't work) — generate it in Contentful
under **Settings → API keys → Content management tokens**.

`CONTENTFUL_ORGANIZATION_ID` is required **only by the taxonomy CRUD scripts**
(`taxonomy:create`, `taxonomy:delete`) — concept schemes and concepts are managed at the
organization level, not per space. Everything else ignores it.

## Options (supported by every script)

| Env var | Effect |
| --- | --- |
| `DRY_RUN=true` | Print per-entry diffs, write nothing (skips the confirm prompt). |
| `ENTRY_ID=<sys.id>` | Restrict the run to a single entry — an extra-safe trial. |
| `CONTENTFUL_ENVIRONMENT=<env>` | Target a non-master environment (default: `master`). |

Without `DRY_RUN`, every script prints the migration plan and prompts before applying.
All scripts skip entries that wouldn't change (no rewrite, no republish) and use
`shouldPublish: 'preserve'` (published entries stay published, drafts stay drafts).

## Pausing deploys during a migration

Publishing entries fires Contentful webhooks that each trigger a site rebuild, so a migration
touching many entries can produce redundant deploys. In practice the "Web" workflow's
`cancel-in-progress` concurrency already collapses a publish storm into roughly one build, so this
is rarely worth doing.

When you do want a hard freeze — a long migration, or one you expect to interrupt — disable the
workflow for the duration and trigger a single build at the end:

```bash
gh workflow disable web.yml    # before the migration
# … run the migration …
gh workflow enable web.yml     # after
gh workflow run web.yml        # one build that picks up everything at once
```

⚠️ Re-enable it. A disabled workflow silently drops every publish and push until someone notices.

## Scripts

### `npm run migrate:headings` — bump heading levels up

`scripts/bump-heading-levels.js`. Part of the H1 restructure (entry titles moved from
`<h2>` to `<h1>` in the site templates): bumps every in-body Markdown heading up one
level (`###` → `##`, `####` → `###`) in `article` `intro`/`body` and `page` `body`, so
the document outline stays intact. Skips fenced code blocks; single-pass, so headings
are never double-shifted.

⚠️ Deploy the `web/`/`api/` template + CSS changes **before** running this, then:

```bash
DRY_RUN=true npm run migrate:headings   # review the diffs first
npm run migrate:headings                # apply (prompts before writing)
```

### `npm run migrate:headings:revert` — rollback for the above

`scripts/revert-heading-levels.js`. Pushes every heading back down one level
(`##` → `###`). Exact inverse for this site's content: no level-1 or level-6 headings
exist, so a bump + revert round-trip is byte-identical.

### `npm run fix:degrees` — º → °

`scripts/fix-degrees.js`. Replaces the masculine ordinal indicator (`º`, U+00BA), often
typed by mistake, with the proper degree sign (`°`, U+00B0) in `article` `intro`/`body`.
Mirrors the render-time helper `fix_degrees` in `web/lib/helpers/text_helpers.rb`.

### `npm run fix:paces` — drop redundant "min" in paces

`scripts/fix-paces.js`. Fixes pace notation in `article` `intro`/`body`, in two passes:
(1) a `M:SS` time already carries the minutes, so `5:25 min/km` is redundant and becomes
`5:25/km` (also fixes the imperial value inside `data-imperial="… min/mi"` attributes);
(2) normalizes per-100 swim-pace spacing to the site's unit style (a space between number and
unit, like `2.4 km`), so `2:16/100m` → `2:16/100 m` and `1:12/100yd` → `1:12/100 yd` — including
paces already authored without `min`. Both passes are anchored on the preceding time, so a bare
`5 min/km` (no seconds) is left alone. Units: `km`, `mi`, `100 yd`, `100 m`. Source-content only
— no render-time counterpart.

```bash
ENTRY_ID=<sys.id> DRY_RUN=true npm run fix:paces   # trial one entry (optional)
DRY_RUN=true npm run fix:paces                     # review the plan
npm run fix:paces                                  # apply (prompts before writing)
```

## Tags → taxonomy migration

A grouped set of scripts that move the blog from Contentful **metadata tags** to a
**taxonomy** (`topics` concept scheme + a `races` branch). The concept vocabulary,
hierarchy, slug rules, static extra races, and the article-slug → race map all live in
`scripts/lib/taxonomy.js` — edit that one file to adjust the design.

⚠️ **Concepts and schemes are organization-level and permanent-ish** — there is no
environment sandbox for them, and their ids become the `/tagged/<id>` URL segments on the
site. Entry *assignment* (`taxonomy:assign`) is environment-scoped, so rehearse it on a
sandbox first. Dry-run everything.

The current design is **two schemes** — `sports` (Triathlon › distances › races, Running,
Cycling, Swimming) and `topics` (Race Reports, News, Reviews, Training, Tech, …). Switching
to it is a **teardown + rebuild** (the apps have no legacy-tag fallback, so old and new
taxonomies can't be half-live). Iterate on the design first, then cut over with builds paused.

**Review loop (no writes):** edit `scripts/lib/taxonomy.js` — the single source of truth for
concepts, `altLabels`, `description` copy, and the per-article assignment map — then
`npm run taxonomy:preview` and repeat until happy.

Run order (DRY_RUN each first; consider **pausing deploys** during 2–8, above):

| Step | Command | What it does |
| --- | --- | --- |
| 1 | `taxonomy:preview` | Read-only: render the design + each article's resolved full-path assignment; validate. No writes. |
| 2 | `taxonomy:unassign` | Clear `metadata.concepts` on all articles (so the old concepts can be deleted). |
| 3 | `taxonomy:delete` | Delete the entire current org taxonomy (all schemes + concepts). |
| 4 | `taxonomy:create` | Create both schemes + all concepts. **Org-level.** Needs `CONTENTFUL_ORGANIZATION_ID`. |
| 5 | `taxonomy:validate-article` | Add both schemes as taxonomy validations on the `article` type. |
| 6 | `taxonomy:assign` | Set each article's `metadata.concepts` to its full concept path (expands the map's most-specific concepts up their `broader` chains). |
| 7 | `taxonomy:describe` | Write each concept's `definition` + `altLabels` from the concept list. |
| 8 | `taxonomy:redirects` | Upsert Contentful `redirect` entries for moved `/tagged/*` URLs. **Run before re-importing web data** (old paths come from `web/data/tags.json`). |
| — | *(deploy web + api, resume builds, backfill)* | |

Inverses: `taxonomy:validate-article:revert` (clear validations); `taxonomy:unassign` +
`taxonomy:delete` are themselves the teardown.

Every script supports `DRY_RUN` / `ENTRY_ID` / `CONTENTFUL_ENVIRONMENT` as above.

### Preflight (Phase 0)

Before step 1, confirm the two things the apps depend on and take a backup. The two
verification curls use the **delivery/preview** tokens from the `web/` and `api/` apps (CPA
for `preview.contentful.com`, CDA for `cdn.contentful.com`) — those live in those apps'
`.env` files, not `contentful/.env`, so set them inline; the backup runs as an npm script.

```bash
# 1. GraphQL exposes concept ids on entries (both apps read this):
curl -s "https://graphql.contentful.com/content/v1/spaces/$CONTENTFUL_SPACE" \
  -H "Authorization: Bearer $CONTENTFUL_DELIVERY_TOKEN" -H 'Content-Type: application/json' \
  --data '{"query":"{ __type(name:\"ContentfulMetadata\"){ fields { name } } }"}'
# → the fields list must include "concepts".

# 2. The delivery taxonomy REST endpoint works on BOTH hosts the apps use.
#    web hits preview.contentful.com (its CONTENTFUL_TOKEN is a CPA token); api hits cdn.contentful.com.
#    Path is /taxonomy/concepts (singular). After step 1 it returns items with prefLabel + broader.
for host in cdn preview; do
  curl -s "https://$host.contentful.com/spaces/$CONTENTFUL_SPACE/environments/master/taxonomy/concepts?limit=1" \
    -H "Authorization: Bearer <token for that host>" | head -c 400; echo
done

# 3. Backup master before any write (loads .env like the other scripts):
npm run backup
```

With no fallback, the apps require the taxonomy at build/request time — hence the paused-builds
cutover: nothing rebuilds while the taxonomy is torn down and rebuilt.

### Individual scripts

- **`taxonomy:preview`** (`scripts/preview-taxonomy.js`) — read-only. Renders every concept
  (by scheme, with altLabels + description) and each article's resolved full-path assignment,
  cross-checks coverage against `web/data/articles.json`, and validates the design. No creds.
- **`taxonomy:create`** (`scripts/create-taxonomy.js`) — creates/reconciles both schemes +
  all concepts from `lib/taxonomy.js` (prefLabel + broader only; describe owns the copy).
- **`taxonomy:describe`** (`scripts/set-descriptions.js`) — writes each concept's `definition`
  and `altLabels` from `lib/taxonomy.js`. Idempotent; re-run after editing copy. ⚠ Reconciles
  **every** concept, so it will overwrite descriptions edited directly in Contentful — sync
  those back into `lib/taxonomy.js` first, or use the scoped script below.
- **`taxonomy:describe-events`** (`scripts/set-event-descriptions.js`) — one-off, scoped to the
  17 race/event concepts (the ones with copy in `event-descriptions.md`). Patches **only their
  `/definition`** from `lib/taxonomy.js`, never `altLabels` and never any other concept, so
  descriptions hand-edited in Contentful for the topic/distance/discipline concepts are left
  alone. Idempotent, skip-unchanged, `DRY_RUN`.
- **`taxonomy:assign`** (`scripts/assign-concepts.js`) — sets each `article`'s
  `metadata.concepts` from the `ASSIGNMENTS` map, expanding each concept up its `broader`
  chain (full path). Skip-unchanged, publish-preserving. Reports articles with no assignment.
- **`taxonomy:unassign`** (`scripts/unassign-concepts.js`) — clears `metadata.concepts`.
- **`taxonomy:delete`** (`scripts/delete-taxonomy.js`) — deletes ALL org schemes + concepts
  (deepest-first); refuses while any entry links a concept (unassign first).
- **`taxonomy:validate-article`** / **`:revert`** — add both scheme validations / clear all.
- **`taxonomy:redirects`** (`scripts/create-redirects.js`) — upserts Contentful `redirect`
  entries (301) for `/tagged/*` archive URLs that moved (old paths from `web/data/tags.json`,
  new from the design) plus retired ids (`ironman`/`ironman-703`/`olympic`/`races`). Run
  before re-importing.

## Recommended workflow for destructive migrations

1. **Backup**: `npm run backup` (exports the space via contentful-cli, loading `.env`).
2. **Dry-run** and review the diffs (`DRY_RUN=true npm run …`).
3. Optionally test on a **sandbox environment** (`CONTENTFUL_ENVIRONMENT=sandbox`) or a
   **single entry** (`ENTRY_ID=…`) first.
4. Apply to master. Contentful's per-entry version history (snapshots) is the
   last-resort fallback; pair anything destructive with an inverse script.

Conventions for writing new migrations are in [`CLAUDE.md`](CLAUDE.md).
