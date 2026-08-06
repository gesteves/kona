// One-off Contentful migration: fixes pace notation in article intro/body, in two passes.
//   1. Drops the redundant "min" from a M:SS pace ("5:25 min/km" → "5:25/km"), including
//      inside data-imperial attributes.
//   2. Spaces out per-100 swim paces to match the site's unit style ("2:16/100m" →
//      "2:16/100 m").
// Both are anchored on the M:SS time, so a bare "5 min/km" is deliberately left alone.
//
// Run: `npm run fix:paces` from contentful/. Options:
//   DRY_RUN=true                  print per-entry diffs, write nothing
//   ENTRY_ID=<sys.id>             restrict to a single entry
//   CONTENTFUL_ENVIRONMENT=<env>  target a non-master environment (default: master)
const { runMigration } = require('contentful-migration');

const FIELDS = ['body', 'intro'];

const fixPaces = (text) =>
  text
    // The M:SS anchor is what keeps a bare "5 min/km" safe.
    .replace(/(\d{1,2}:\d{2})\s?min\/(km|mi|100\s?yd|100\s?m)/g, '$1/$2')
    .replace(/(\d{1,2}:\d{2}\/100)(m|yd)\b/g, '$1 $2');

// Prints the changed lines of a field as a small before/after diff.
function logDiff(label, field, before, after) {
  const beforeLines = before.split('\n');
  const afterLines = after.split('\n');
  console.log(`\n--- ${label} (${field}) ---`);
  beforeLines.forEach((line, i) => {
    if (line !== afterLines[i]) {
      console.log(`  - ${line}`);
      console.log(`  + ${afterLines[i]}`);
    }
  });
}

const dryRun = process.env.DRY_RUN === 'true';
const onlyId = process.env.ENTRY_ID; // optional: restrict the fix to this one entry

function migrationFunction(migration) {
  migration.transformEntries({
    contentType: 'article',
    from: ['title', ...FIELDS],
    to: FIELDS,
    // Runs once per locale per entry; `meta.id` is the entry's sys.id.
    transformEntryForLocale: (fields, locale, meta) => {
      if (onlyId && meta.id !== onlyId) return undefined; // skip all but the target entry
      const title = fields.title?.[locale] || '(untitled)';
      const out = {};
      for (const field of FIELDS) {
        const value = fields[field]?.[locale];
        if (typeof value !== 'string') continue;
        const fixed = fixPaces(value);
        if (fixed !== value) {
          out[field] = fixed;
          if (dryRun) logDiff(`article ${meta.id}: ${title}`, field, value, fixed);
        }
      }
      if (dryRun) return undefined; // log only, write nothing
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
    'Missing CONTENTFUL_SPACE and/or CONTENTFUL_MANAGEMENT_TOKEN — set them in contentful/.env.'
  );
  process.exit(1);
}

runMigration({
  spaceId,
  accessToken,
  environmentId: process.env.CONTENTFUL_ENVIRONMENT || 'master',
  migrationFunction,
  yes: dryRun, // dry runs write nothing, so skip the prompt; real runs show the plan and ask
}).catch(() => process.exit(1));
