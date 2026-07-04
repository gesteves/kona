# Contentful content migrations

One-off scripts that rewrite content **in Contentful itself**, run locally. This
directory lives outside `web/` so editing these scripts never triggers a Netlify build.

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

## Tags → taxonomy migration

A grouped set of scripts that move the blog from Contentful **metadata tags** to a
**taxonomy** (`topics` concept scheme + a `races` branch). The concept vocabulary,
hierarchy, slug rules, static extra races, and the article-slug → race map all live in
`scripts/lib/taxonomy.js` — edit that one file to adjust the design.

⚠️ **Concepts and schemes are organization-level and permanent-ish** — there is no
environment sandbox for them, and their ids become the `/tagged/<id>` URL segments on the
site. Entry *assignment* (`taxonomy:assign`) is environment-scoped, so rehearse it on a
sandbox first. Dry-run everything.

Run order (additive-first, so the site never has a window with missing categories):

| Step | Command | What it does |
| --- | --- | --- |
| 1 | `taxonomy:create` | Create/reconcile the `topics` scheme + all concepts (idempotent). **Org-level.** Needs `CONTENTFUL_ORGANIZATION_ID`. Only touches `prefLabel`/`broader`, never descriptions/synonyms you add later. |
| 2 | `taxonomy:validate-article` | Add the scheme as a taxonomy validation on the `article` type (shows the editor Taxonomy tab). |
| 3 | `taxonomy:assign` | Set each article's `metadata.concepts` (tags 1:1 + race concept). Idempotent, skip-unchanged, publish-preserving. Rehearse with `DRY_RUN`/`ENTRY_ID`/a sandbox env. |
| — | *(deploy web + api)* | Both apps read concepts with a legacy-tag fallback, so deploy order is safe. |
| 4 | `taxonomy:remove-tags` | **Phase 5 only**, after everything's verified in production: strip the migrated `metadata.tags` (private tags like `short` are preserved). Second republish of tagged entries. |

Inverses: `taxonomy:unassign` (clear concepts), `taxonomy:delete` (remove scheme +
concepts — refuses while any entry still links one, so unassign first),
`taxonomy:validate-article:revert`, `taxonomy:restore-tags` (rebuild tags from concepts,
skipping race concepts).

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

Both apps fall back to legacy tags until concepts are assigned and the taxonomy endpoint
returns data, so the code can deploy before or after the content migration.

### Redirects for the 6 moved tag URLs

Hierarchy nests child tags under their parents, so six `/tagged/*` URLs move. Add these as
Contentful `redirect` entries (same as the existing `/tagged/bikes → /tagged/cycling`) — no
script needed:

| From | To |
| --- | --- |
| `/tagged/ironman` | `/tagged/triathlon/ironman` |
| `/tagged/ironman-703` | `/tagged/triathlon/ironman-703` |
| `/tagged/olympic` | `/tagged/triathlon/olympic` |
| `/tagged/half-marathon` | `/tagged/running/half-marathon` |
| `/tagged/nutrition-hydration` | `/tagged/training/nutrition-hydration` |
| `/tagged/zwift` | `/tagged/apps/zwift` |

### Individual scripts

- **`taxonomy:create`** (`scripts/create-taxonomy.js`) — reconciles concepts + the scheme
  from `lib/taxonomy.js`; race concepts are derived from live `event` entries plus the
  static extras. Re-run after adding events/races.
- **`taxonomy:describe`** (`scripts/set-descriptions.js`) — sets each concept's `definition`
  (the description shown on its `/tagged` archive page and in that page's meta/OG tags). The
  copy lives in the script — tweak it, then re-run (idempotent, skip-unchanged). Markdown is
  supported. Org-level, so it needs `CONTENTFUL_ORGANIZATION_ID`. Optional; run any time after
  `taxonomy:create`. (`taxonomy:create` never writes descriptions, so the two don't conflict.)
- **`taxonomy:delete`** (`scripts/delete-taxonomy.js`) — inverse; deletes the scheme then
  concepts deepest-first; refuses while any entry links a concept.
- **`taxonomy:assign`** (`scripts/assign-concepts.js`) — assigns concepts to `article`
  entries per the rules in `lib/taxonomy.js`.
- **`taxonomy:unassign`** (`scripts/unassign-concepts.js`) — inverse; clears
  `metadata.concepts`.
- **`taxonomy:validate-article`** / **`:revert`** — add / clear the article taxonomy
  validation.
- **`taxonomy:remove-tags`** (`scripts/remove-tags.js`) / **`taxonomy:restore-tags`** —
  remove the migrated `metadata.tags` / rebuild them from concepts. Non-concept tags (e.g.
  the private `short` marker) are preserved by remove and merged back by restore; race
  concepts, which were never tags, are skipped.

## Recommended workflow for destructive migrations

1. **Backup**: `npm run backup` (exports the space via contentful-cli, loading `.env`).
2. **Dry-run** and review the diffs (`DRY_RUN=true npm run …`).
3. Optionally test on a **sandbox environment** (`CONTENTFUL_ENVIRONMENT=sandbox`) or a
   **single entry** (`ENTRY_ID=…`) first.
4. Apply to master. Contentful's per-entry version history (snapshots) is the
   last-resort fallback; pair anything destructive with an inverse script.

Conventions for writing new migrations are in [`CLAUDE.md`](CLAUDE.md).
