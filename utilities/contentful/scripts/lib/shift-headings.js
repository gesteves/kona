// The shared code of bump-heading-levels.js and revert-heading-levels.js.
//
// It moves each ATX Markdown heading by `delta` levels in one pass, thus it never moves a heading
// two times. It does not change a fenced code block, thus a `#` comment line in code stays the
// same.
//
// The env vars, as in each other file in this directory:
//   DRY_RUN=true                  Show the changes of each entry and write nothing.
//   ENTRY_ID=<sys.id>             Use one entry only.
//   CONTENTFUL_ENVIRONMENT=<env>  Use an environment that is not master. The default is master.
const { runMigration } = require('contentful-migration');

const FENCE = /^\s{0,3}(```|~~~)/;
const ATX_HEADING = /^(#{1,6})(\s)/;

const TARGETS = [
  { contentType: 'article', fields: ['intro', 'body'] },
  { contentType: 'page', fields: ['body'] },
];

// Moves each ATX heading level by `delta`, with a minimum of 1 and a maximum of 6. It returns the
// new text.
function shiftHeadings(text, delta) {
  let inFence = false;
  return text
    .split('\n')
    .map((line) => {
      if (FENCE.test(line)) {
        inFence = !inFence;
        return line;
      }
      if (inFence) return line;
      return line.replace(ATX_HEADING, (_, hashes, space) => {
        const level = Math.min(6, Math.max(1, hashes.length + delta));
        return '#'.repeat(level) + space;
      });
    })
    .join('\n');
}

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

// Makes the migration and runs it. An entry, or a locale, with no heading change returns undefined.
// Thus the code does not write it and does not publish it again, and the <lastmod> in the sitemap,
// the Atom feed, and the webhooks stay quiet for content that does not change.
function runHeadingShift(delta) {
  const dryRun = process.env.DRY_RUN === 'true';
  const onlyId = process.env.ENTRY_ID; // optional: restrict to this one entry

  const spaceId = process.env.CONTENTFUL_SPACE;
  const accessToken = process.env.CONTENTFUL_MANAGEMENT_TOKEN;

  if (!spaceId || !accessToken) {
    console.error(
      'Missing CONTENTFUL_SPACE and/or CONTENTFUL_MANAGEMENT_TOKEN — set them in contentful/.env.'
    );
    process.exit(1);
  }

  function migrationFunction(migration) {
    for (const { contentType, fields } of TARGETS) {
      migration.transformEntries({
        contentType,
        from: ['title', ...fields],
        to: fields,
        // This runs one time for each locale of each entry. `meta.id` is the sys.id of the
        // entry.
        transformEntryForLocale: (fromFields, locale, meta) => {
          if (onlyId && meta.id !== onlyId) return undefined; // skip all but the target entry
          const title = fromFields.title?.[locale] || '(untitled)';
          const out = {};
          for (const field of fields) {
            const value = fromFields[field]?.[locale];
            if (typeof value !== 'string') continue;
            const shifted = shiftHeadings(value, delta);
            if (shifted !== value) {
              out[field] = shifted;
              if (dryRun)
                logDiff(
                  `${contentType} ${meta.id}: ${title}`,
                  field,
                  value,
                  shifted
                );
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
  }

  runMigration({
    spaceId,
    accessToken,
    environmentId: process.env.CONTENTFUL_ENVIRONMENT || 'master',
    migrationFunction,
    yes: dryRun, // dry runs write nothing, so skip the prompt; real runs show the plan and ask
  }).catch(() => process.exit(1));
}

module.exports = { shiftHeadings, runHeadingShift };
