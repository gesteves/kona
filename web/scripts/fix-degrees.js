// One-off Contentful migration: replaces the masculine ordinal indicator (º, U+00BA),
// often typed by mistake, with the proper degree sign (°, U+00B0) in article body/intro.
// Mirrors the web render-time helper `fix_degrees` (lib/helpers/text_helpers.rb).
//
// Run with `npm run fix:degrees`, which loads web/.env (via `node --env-file`) so
// CONTENTFUL_SPACE and CONTENTFUL_MANAGEMENT_TOKEN are available. It prints the plan and
// prompts before applying. Optional env vars:
//   ENTRY_ID=<sys.id>             restrict the fix to a single entry (extra-safe trial)
//   CONTENTFUL_ENVIRONMENT=<env>  target a non-master environment (default: master)
const { runMigration } = require('contentful-migration');

const FIELDS = ['body', 'intro'];
const onlyId = process.env.ENTRY_ID; // optional: restrict the fix to this one entry

function fixDegrees(migration) {
  migration.transformEntries({
    contentType: 'article',
    from: FIELDS,
    to: FIELDS,
    // Runs once per locale per entry; `meta.id` is the entry's sys.id.
    transformEntryForLocale: (fields, locale, meta) => {
      if (onlyId && meta.id !== onlyId) return undefined; // skip all but the target entry
      const out = {};
      for (const field of FIELDS) {
        const value = fields[field]?.[locale];
        if (typeof value !== 'string') continue;
        const fixed = value.replace(/º/g, '°'); // º → °
        if (fixed !== value) out[field] = fixed;
      }
      // Return undefined when nothing changed so the entry is skipped (no version bump).
      return Object.keys(out).length ? out : undefined;
    },
    shouldPublish: 'preserve', // re-publish if it was published; leave drafts as drafts
  });
}

const spaceId = process.env.CONTENTFUL_SPACE;
const accessToken = process.env.CONTENTFUL_MANAGEMENT_TOKEN;

if (!spaceId || !accessToken) {
  console.error(
    'Missing CONTENTFUL_SPACE and/or CONTENTFUL_MANAGEMENT_TOKEN — set them in web/.env.'
  );
  process.exit(1);
}

runMigration({
  spaceId,
  accessToken,
  environmentId: process.env.CONTENTFUL_ENVIRONMENT || 'master',
  migrationFunction: fixDegrees,
  yes: false, // show the plan and prompt before applying
}).catch(() => process.exit(1));
