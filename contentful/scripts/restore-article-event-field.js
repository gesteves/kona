// Best-effort inverse of remove-article-event-field.js: re-creates the `event` reference
// field on the `article` content type (a single link to an `event` entry).
//
// ⚠️ This restores the FIELD only, not the per-entry links deleteField discarded — those
// are unrecoverable except from the `contentful space export` backup taken before the
// removal. Field settings here mirror the original as closely as possible; adjust the
// validations/appearance in the web app if they differ from your backup.
//
// Env: CONTENTFUL_SPACE, CONTENTFUL_MANAGEMENT_TOKEN, CONTENTFUL_ENVIRONMENT (default master).
// Run: `npm run migrate:remove-event-field:revert`.

const { runMigration } = require('contentful-migration');

function migrationFunction(migration) {
  const article = migration.editContentType('article');
  article
    .createField('event')
    .name('Event')
    .type('Link')
    .linkType('Entry')
    .validations([{ linkContentType: ['event'] }])
    .required(false);
  article.changeFieldControl('event', 'builtin', 'entryLinkEditor');
}

const spaceId = process.env.CONTENTFUL_SPACE;
const accessToken = process.env.CONTENTFUL_MANAGEMENT_TOKEN;

if (!spaceId || !accessToken) {
  console.error('Missing CONTENTFUL_SPACE and/or CONTENTFUL_MANAGEMENT_TOKEN — set them in contentful/.env.');
  process.exit(1);
}

runMigration({
  spaceId,
  accessToken,
  environmentId: process.env.CONTENTFUL_ENVIRONMENT || 'master',
  migrationFunction,
  yes: false,
}).catch(() => process.exit(1));
