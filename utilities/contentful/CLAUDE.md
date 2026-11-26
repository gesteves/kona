# utilities/contentful — content migrations & the taxonomy toolkit

Node scripts that write the content **in Contentful** through the CMA. Refer to the root
[`CLAUDE.md`](../../CLAUDE.md), which also has the rules for a comment.

⚠️ [`README.md`](README.md) gives the use of each script, its flags, and the full taxonomy
**runbook**. **Keep it correct** each time that you add, change, or remove a script.

⚠️ The management token stays in the `.env` of this directory, and never in `web/.env`. The build
must not hold a token that can write.

## The taxonomy

⚠️ **The Contentful UI is the source of the taxonomy, and `scripts/lib/taxonomy.js` is not.** The
owner edits the concepts and the assignments in the UI, and that file is older than those edits.
Each `taxonomy:*` script reads that file. Thus a script that writes replaces each edit from the UI,
and it gives no message. Ask the owner before you run one.

- **A scheme is one axis that a reader can browse**, separate from each other axis, and it applies
  to each article. Sports is one. Tech and Training are *values*, thus they are concepts in Topics.
  A future Locations scheme is a third scheme and changes nothing in the other two.
- Each description is **Markdown**. Each link in it must be **relative** (`/tagged/…`). Never write
  the production host in the text.
- **A new parent moves the `/tagged/*` archive URL of a concept.** Add a Contentful `redirect`
  **entry** for the old URL. Never write a redirect in the code.
- After a write to the taxonomy, run `rake redis:clear` in `web/`. The build caches the taxonomy for
  approximately one hour, and the next import otherwise gives the old data.
- After a new assignment, run `rake standard_site:backfill` in `api/`, thus its records get the new
  concept names.
- ⚠️ **A change to the structure has no fallback.** Both apps need the taxonomy at build time and at
  request time. Thus do it as one cutover **with the builds off**. [`README.md`](README.md) has the
  runbook in order.

## Migrations

⚠️ **`fix:degrees`, `fix:paces`, and `migrate:headings` already ran against production.** They stay
as templates only. Never run them again.

Use `scripts/fix-degrees.js` and `scripts/bump-heading-levels.js` as templates for a new one.

- **Do nothing for an entry with no change.** Return `undefined` from `transformEntryForLocale`. A new
  publish increases `sys.publishedAt`, which changes the `<lastmod>` in the sitemap and the feeds,
  and it sends the Contentful webhooks, which start a PDS sync and a site build.
- **Use `shouldPublish: 'preserve'`.** A published entry stays published, and a draft stays a draft.
- Accept `DRY_RUN`, `ENTRY_ID`, and `CONTENTFUL_ENVIRONMENT` in each script.
- ⚠️ **It is difficult to go back after a migration.** Do a dry run first, use a sandbox
  environment, run `npm run backup` before you change master, and write an opposite script for each
  transform that removes data.
- If a migration needs a change to a template or to the CSS in `web/`, deploy the code first, then
  run the migration. The content and the code cannot go to production at the same moment.
