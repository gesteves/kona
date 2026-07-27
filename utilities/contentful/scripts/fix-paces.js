// One-off Contentful migration: fixes pace notation in article intro/body.
//
// 1. A pace like "5:25 min/km" already carries the minutes in the M:SS time, so the "min" is
//    redundant — the correct form is "5:25/km". Drops the " min" while keeping the time and unit
//    ("5:25 min/km" → "5:25/km"). Also fixes the imperial value inside data-imperial="… min/mi"
//    attributes, since that's the same text pattern.
// 2. Normalizes per-100 swim-pace spacing to the site's unit style — everywhere else a space
//    separates number and unit ("2.4 km", "100 meters"), so "2:16/100m" → "2:16/100 m" and
//    "1:12/100yd" → "1:12/100 yd". The 6 already-min-less paces authored without the space get
//    fixed too, so all per-100 paces end up consistent.
//
// Both matches are anchored on the preceding M:SS time, so a bare "5 min/km" (a pace with no
// seconds) is deliberately NOT touched — "5/km" would be wrong. Units covered: km, mi, 100 yd,
// 100 m. Purely a source-content correction; there's no render-time counterpart.
//
// Run with `npm run fix:paces` (from contentful/), which loads contentful/.env (via
// `node --env-file`) so CONTENTFUL_SPACE and CONTENTFUL_MANAGEMENT_TOKEN are available. Options:
//   DRY_RUN=true                  print per-entry diffs, write nothing (skips the prompt)
//   ENTRY_ID=<sys.id>             restrict the fix to a single entry (extra-safe trial)
//   CONTENTFUL_ENVIRONMENT=<env>  target a non-master environment (default: master)
const { runMigration } = require('contentful-migration');

const FIELDS = ['body', 'intro'];

const fixPaces = (text) =>
  text
    // 1. Drop the redundant "min". \d{1,2}:\d{2} anchors on the time so bare "5 min/km" is safe.
    .replace(/(\d{1,2}:\d{2})\s?min\/(km|mi|100\s?yd|100\s?m)/g, '$1/$2')
    // 2. Space out per-100 paces missing the space ("2:16/100m" → "2:16/100 m").
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
