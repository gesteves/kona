// PHASE 5 cleanup — run only after `related_race_reports` is confirmed concept-driven in
// production. Removes the `event` reference field from the `article` content type: once
// race reports carry their race concept, the "More Reports From This Race" widget groups
// by that concept and no longer needs the article→event link.
//
// The `event` content type and its entries STAY (the Upcoming Races widget needs them);
// only the reference field on `article` is deleted.
//
// ⚠️ deleteField discards the per-entry links irreversibly — the inverse
// (restore-article-event-field.js) re-creates the field but CANNOT repopulate the links.
// The `contentful space export` backup is the real safety net. Deleting a field also
// requires it to be omitted/disabled first; contentful-migration handles that.
//
// Env: CONTENTFUL_SPACE, CONTENTFUL_MANAGEMENT_TOKEN, CONTENTFUL_ENVIRONMENT (default master).
// Run: `npm run migrate:remove-event-field`.

const { runMigration } = require('contentful-migration');

function migrationFunction(migration) {
  const article = migration.editContentType('article');
  article.deleteField('event');
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
