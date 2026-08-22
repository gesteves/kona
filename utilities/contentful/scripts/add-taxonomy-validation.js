// Adds the two concept schemes (`sports` and `topics`) as taxonomy validations on the `article`
// content type. Thus the editor shows a Taxonomy tab and a person selects a concept from each
// scheme. They are not `required`: assign-concepts.js sets the concepts, and a required field would
// stop an edit.
//
// The schemes must exist first, thus run taxonomy:create. contentful-migration cannot make a concept
// or a scheme: it can only name one in a validation, as this script does.
//
// The env vars: CONTENTFUL_SPACE, CONTENTFUL_MANAGEMENT_TOKEN, and CONTENTFUL_ENVIRONMENT, whose
// default is master.
// To run it: `npm run taxonomy:validate-article`. To remove it:
// `npm run taxonomy:validate-article:revert`.

const { runMigration } = require('contentful-migration');
const { SCHEMES } = require('./lib/taxonomy');

function migrationFunction(migration) {
  const article = migration.editContentType('article');
  for (const scheme of SCHEMES) article.addTaxonomyValidation(scheme.id, 'TaxonomyConceptScheme');
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
