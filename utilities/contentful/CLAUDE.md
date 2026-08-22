# utilities/contentful — content migrations & the taxonomy toolkit

Node scripts that read and write the content **in Contentful**. The transforms in
`web/lib/helpers/` are different: those run at render time. These scripts are in `utilities/`, thus
a run or an edit here never starts a build, a deploy, or an edge-cache purge. Refer to the root
[`CLAUDE.md`](../../CLAUDE.md), which also has the rules for a comment.

⚠️ **Write each comment, all the inline documentation, and each change to a `CLAUDE.md` file in
ASD-STE100 Simplified Technical English, and keep it short.** The root
[`CLAUDE.md`](../../CLAUDE.md) has the full rule.

There are two types of script here, and they use **different Contentful APIs**:

- **A content migration that runs one time** — it changes the fields of an entry with
  `contentful-migration` (`runMigration` and `transformEntries`). Some of them already ran, and they
  stay here as templates only.
- **The taxonomy toolkit** — it controls the SKOS taxonomy of the organization, through the **plain
  client** of `contentful-management`, at the organization level. You can run each of these more
  than one time. They make Contentful agree with one source file.

⚠️ [`README.md`](README.md) gives the use of each script, its flags, and the full taxonomy
**runbook**. **Keep it correct** each time that you add, change, or remove a script.

## Commands

Run each command from this directory. Do `npm install` one time first. The npm scripts load the
`.env` of this directory with `node --env-file`. Copy `.env.example` and give a value to each of
these:

- `CONTENTFUL_SPACE` — the same value as in `web/.env`.
- `CONTENTFUL_MANAGEMENT_TOKEN` — a CMA token. The *delivery* token of the web app cannot write.
- `CONTENTFUL_ORGANIZATION_ID` — for the **taxonomy scripts only**, because a concept and a scheme
  belong to the organization.

The management token is here and not in `web/.env`, because the build never uses it. You need no
`contentful login`. `taxonomy:preview` needs no credentials.

## The taxonomy

The tags of the blog are a Contentful **SKOS taxonomy**: concept **schemes** and **concepts**, and
both belong to the **organization**. Three results of that:

- **A write** goes through the CMA plain client at the organization: `client.concept.*` and
  `client.conceptScheme.*`. Refer to `createPlainClient` and `getExistingConcepts` in
  `lib/taxonomy.js`. Each edit is a **JSON Patch** operation against the `sys.version` of the
  concept. A list of concepts comes one page at a time with a cursor (`page.pages.next`), and not
  with skip and limit.
- **The two apps read the taxonomy in a different way.** Do not confuse the two ways. The GraphQL
  `contentfulMetadata.concepts` gives the concept **ids** only, and each app joins those ids to the
  names and the tree from the **delivery or preview REST** endpoint `…/taxonomy/concepts`. `web`
  uses the preview host, and `api` uses the cdn host. No code that the apps use can *write* the
  taxonomy.

### Single source of truth: `scripts/lib/taxonomy.js`

Each taxonomy script reads this file, thus the preview shows exactly what the script does:

- `SCHEMES` — the two schemes: `sports` and `topics`.
- `CONCEPTS` — `{ id, name, scheme, broader, altLabels, description }`. `broader` is one parent id,
  and a chain of more than one level is permitted. `description` is Markdown.
- `ASSIGNMENTS` — `article slug → { sports: <most specific id or null>, topics: [ids] }`. The map
  holds the **leaf** only. Each script adds the parents from the `broader` chain and writes the
  **full path**.
- The helper functions, the CMA client, and the code that reads the environment.

**To change the taxonomy, edit this file and run the correct script again.** That applies when you
add a concept, change the name of one, edit its text, give an article different concepts, or add the
planned Locations scheme. Each script is safe to run more than one time. Always run
`npm run taxonomy:preview` first: it is read-only, it needs no credentials, and it compares the
result with `../../web/data/articles.json`.

### Design rules

- A **scheme** is one axis that a reader can browse, and that is separate from each other axis and
  applies to each article. Sports is such an axis, and a future Locations scheme is one also. Tech
  and Training are *values*, thus they are concepts in Topics. To add Locations later, you need a
  third scheme and a map from each race to a location, and you change nothing in Sports and in
  Topics.
- Each article has the **full concept path** of each scheme, and not the leaf only. Thus the chips,
  the archives, and the breadcrumbs show each level.
- ⚠️ The prefLabels **"Race Reports"** and **"Reviews"** must stay **exactly** those two strings. The
  `share_helpers` of `web` match them, and a new name breaks the feed, the OG data, and the JSON-LD.
- The private **`short`** metadata tag has **no concept**, because the CDA does not show it. The
  assign script and the unassign script must omit each tag with no concept, or they get a 422.
- Each description is **Markdown**. It can contain inline HTML and a Markdown link, but each link
  must be **relative** (`/tagged/…`). Never write the production host in the text.

### Gotchas

- ⚠️ **`taxonomy:describe` changes EVERY concept.** Thus it replaces each description and each set
  of altLabels that a person edited in the Contentful UI, and it gives no message. After such an
  edit in the UI, `lib/taxonomy.js` is no longer correct and it is no longer the source. Put those
  edits into that file before you run the script again, or use `taxonomy:describe-events`, which
  changes the `/definition` of the event concepts only. Use a script with a small scope when you
  want to change some concepts only.
- ⚠️ **There is no fallback to the old behavior.** The apps need the taxonomy at build time and at
  request time. Thus a change to the structure is a cutover **with the builds off**, and not a
  change one step at a time. The steps: backup, unassign, delete, create, validate, assign,
  describe, redirects, deploy, builds on, and then the api backfill. [`README.md`](README.md) has
  the runbook in order.
- **A teardown lets you use the same ids again.** `taxonomy:delete` removes each scheme and each
  concept of the organization, and it removes the most deeply nested concept first. It **stops while
  an entry still has a concept**, thus run `taxonomy:unassign` first. `create` then makes each one
  again with the same id.
- **The URLs change.** A new parent for a concept moves its `/tagged/*` archive URL. Use a Contentful
  `redirect` **entry** for that (`taxonomy:redirects`). That script reads the old paths from
  `web/data/tags.json`. ⚠️ Run it **before** you import the web data again. Never write a redirect
  in the code.
- **The Redis cache**: `web` caches the delivery taxonomy for approximately one hour. After a write
  to the taxonomy, run `rake redis:clear` in `web/`, or the next import gives the old data.
- **The api needs no change** for a taxonomy edit: it only changes a concept id into a name. After a
  new assignment, run `standard_site:backfill`, thus its records get the new concept-name tags.

## Script inventory

**The taxonomy toolkit.** You can run each of these more than one time, and each one reads
`lib/taxonomy.js`:

| npm script | What it does |
|---|---|
| `taxonomy:preview` | Shows the design and checks it. It is read-only, it needs no credentials, and it writes nothing. |
| `taxonomy:create` | Makes each scheme and each concept, and corrects the ones that exist (**prefLabel and broader only**). |
| `taxonomy:describe` | Writes the `definition` and the `altLabels` of **each** concept. ⚠️ It replaces an edit from the UI. |
| `taxonomy:describe-events` | The `/definition` of the event concepts only. |
| `taxonomy:assign` / `taxonomy:unassign` | Sets or clears the `metadata.concepts` of each article. |
| `taxonomy:validate-article` / `:revert` | Adds or removes the two scheme validations on `article`. |
| `taxonomy:delete` | Deletes each scheme and each concept of the organization. Unassign first. |
| `taxonomy:redirects` | Makes or updates a `redirect` entry for each `/tagged/*` URL that moved. |

**A utility:** `backup` calls `space export` and writes a JSON file with a timestamp. Run it before
each migration that removes data.

**The transforms that already ran** against production. They stay here as templates, and you must
not run them again: `fix:degrees`, `fix:paces`, and `migrate:headings` with its `:revert`, which
`lib/shift-headings.js` supports.

## Conventions for new migrations

Use `scripts/fix-degrees.js` and `scripts/bump-heading-levels.js` as templates.

- **Do nothing for an entry with no change.** Return `undefined` from `transformEntryForLocale` when
  nothing changes. A new publish increases `sys.publishedAt`, which changes the `<lastmod>` in the
  sitemap and the Atom feed, and which sends the Contentful webhooks. Those webhooks start a PDS
  sync, a new embedding, and a site build.
- **Use `shouldPublish: 'preserve'`.** A published entry stays published, and a draft stays a draft.
- Accept `DRY_RUN`, `ENTRY_ID`, and `CONTENTFUL_ENVIRONMENT` in each script.
- ⚠️ **It is difficult to go back after a migration.** Do a dry run first, use a sandbox
  environment, make an `npm run backup` export before you change master, and write an opposite
  script for each transform that removes data. The Contentful snapshot of each entry is the last
  way back.
- If a migration needs a template change or a CSS change in `web/`, note the order: the content and
  the code cannot go to production at the same moment. Thus deploy the code first, then run the
  migration.

## Content model notes

- `article` holds **both** an Article and a Short. Both have Markdown in `intro` and in `body`, and
  a Short has `intro` only. Refer to `set_entry_type` in `web/lib/data/contentful.rb`.
- `page` has Markdown in `body` only.
- `redirect` is its own content type. `event` is also its own content type, but the taxonomy scripts
  do not change it: `ASSIGNMENTS` is a fixed map that a person reads. Thus `EVENT_CONTENT_TYPE` in
  `lib/taxonomy.js` is an export that nothing uses, and you can remove it.
