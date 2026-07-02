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

## Recommended workflow for destructive migrations

1. **Backup**: `npx --yes contentful-cli space export --space-id "$CONTENTFUL_SPACE" --management-token "$CONTENTFUL_MANAGEMENT_TOKEN" --environment-id master`
2. **Dry-run** and review the diffs (`DRY_RUN=true npm run …`).
3. Optionally test on a **sandbox environment** (`CONTENTFUL_ENVIRONMENT=sandbox`) or a
   **single entry** (`ENTRY_ID=…`) first.
4. Apply to master. Contentful's per-entry version history (snapshots) is the
   last-resort fallback; pair anything destructive with an inverse script.

Conventions for writing new migrations are in [`CLAUDE.md`](CLAUDE.md).
