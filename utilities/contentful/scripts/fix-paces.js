// A Contentful migration that runs one time: it corrects the pace notation in the intro and the
// body of each article, in two passes.
//   1. It removes the unnecessary "min" from a M:SS pace ("5:25 min/km" becomes "5:25/km"). This
//      includes a pace in a data-imperial attribute.
//   2. It adds a space in a per-100 swim pace, for the unit style of the site ("2:16/100m" becomes
//      "2:16/100 m").
// Both passes need the M:SS time, thus the code does not change a plain "5 min/km", on purpose.
//
// To run it: `npm run fix:paces` from contentful/. The options:
//   DRY_RUN=true                  Show the changes of each entry and write nothing.
//   ENTRY_ID=<sys.id>             Use one entry only.
//   CONTENTFUL_ENVIRONMENT=<env>  Use an environment that is not master. The default is master.
const { runMigration } = require('contentful-migration');

const FIELDS = ['body', 'intro'];

const fixPaces = (text) =>
  text
    // The M:SS time is what keeps a plain "5 min/km" the same.
    .replace(/(\d{1,2}:\d{2})\s?min\/(km|mi|100\s?yd|100\s?m)/g, '$1/$2')
    .replace(/(\d{1,2}:\d{2}\/100)(m|yd)\b/g, '$1 $2');

// Shows the lines of a field that change, with the old text and the new text.
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
    // This runs one time for each locale of each entry. `meta.id` is the sys.id of the entry.
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
      // Return undefined when nothing changes, thus the code does not write the entry and its
      // version does not increase.
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
