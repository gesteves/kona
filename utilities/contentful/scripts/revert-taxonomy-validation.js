// The opposite of add-taxonomy-validation.js: it removes each taxonomy validation from the `article`
// content type, and the Taxonomy tab then goes away. It does not change the concepts of an entry.
// Use taxonomy:unassign for that.
//
// The env vars: CONTENTFUL_SPACE, CONTENTFUL_MANAGEMENT_TOKEN, and CONTENTFUL_ENVIRONMENT, whose
// default is master.
// To run it: `npm run taxonomy:validate-article:revert`.

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
