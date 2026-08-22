// A Contentful migration that runs one time: it puts the correct degree sign (°, U+00B0) in place
// of the masculine ordinal indicator (º, U+00BA), which a person often types by error, in the body
// and the intro of each article. It does the same as the `fix_degrees` helper of web, which runs at
// render time (refer to lib/helpers/text_helpers.rb).
//
// Run it with `npm run fix:degrees` from contentful/. That command loads contentful/.env with
// `node --env-file`, thus CONTENTFUL_SPACE and CONTENTFUL_MANAGEMENT_TOKEN are available. It shows
// the plan and asks before it makes the change. The optional env vars:
//   ENTRY_ID=<sys.id>             Change one entry only, for a safe trial.
//   CONTENTFUL_ENVIRONMENT=<env>  Use an environment that is not master. The default is master.
const { runMigration } = require('contentful-migration');

const FIELDS = ['body', 'intro'];
const onlyId = process.env.ENTRY_ID; // optional: restrict the fix to this one entry

function fixDegrees(migration) {
  migration.transformEntries({
    contentType: 'article',
    from: FIELDS,
    to: FIELDS,
    // This runs one time for each locale of each entry. `meta.id` is the sys.id of the entry.
    transformEntryForLocale: (fields, locale, meta) => {
      if (onlyId && meta.id !== onlyId) return undefined; // skip all but the target entry
      const out = {};
      for (const field of FIELDS) {
        const value = fields[field]?.[locale];
        if (typeof value !== 'string') continue;
        const fixed = value.replace(/º/g, '°'); // º → °
        if (fixed !== value) out[field] = fixed;
      }
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
  migrationFunction: fixDegrees,
  yes: false, // show the plan and prompt before applying
}).catch(() => process.exit(1));
