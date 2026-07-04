// Inverse of add-taxonomy-validation.js: removes all taxonomy validations from the
// `article` content type (hides the Taxonomy tab). Does not touch entries' assigned
// concepts — use taxonomy:unassign for that.
//
// Env: CONTENTFUL_SPACE, CONTENTFUL_MANAGEMENT_TOKEN, CONTENTFUL_ENVIRONMENT (default master).
// Run: `npm run taxonomy:validate-article:revert`.

const { runMigration } = require('contentful-migration');

function migrationFunction(migration) {
  migration.editContentType('article').clearTaxonomyValidations();
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
