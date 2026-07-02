// Shared logic for the heading-level migrations (bump-heading-levels.js and its
// inverse, revert-heading-levels.js). See those scripts for context.
//
// Shifts every ATX Markdown heading (`### Foo`) by `delta` levels, in a single pass
// so headings are never double-shifted, skipping fenced code blocks so `#` comment
// lines in code are never touched. Both content types hold Markdown in plain Text
// fields: `article` (Articles and Shorts) has `intro` + `body`; `page` has `body`.
//
// Env vars (same conventions as fix-degrees.js):
//   DRY_RUN=true                  print per-entry diffs, write nothing
//   ENTRY_ID=<sys.id>             restrict to a single entry (extra-safe trial)
//   CONTENTFUL_ENVIRONMENT=<env>  target a non-master environment (default: master)
const { runMigration } = require('contentful-migration');

const FENCE = /^\s{0,3}(```|~~~)/;
const ATX_HEADING = /^(#{1,6})(\s)/;

const TARGETS = [
  { contentType: 'article', fields: ['intro', 'body'] },
  { contentType: 'page', fields: ['body'] },
];

// Shifts ATX heading levels by `delta`, clamped to 1..6. Returns the new text.
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

// Builds and runs the migration. Entries (and locales) with no heading changes
// return undefined so they're skipped — not rewritten, not republished — keeping
// sitemap <lastmod>, the Atom feed, and webhooks quiet for unchanged content.
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
        // Runs once per locale per entry; `meta.id` is the entry's sys.id.
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
          // Return undefined when nothing changed so the entry is skipped (no version bump).
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
