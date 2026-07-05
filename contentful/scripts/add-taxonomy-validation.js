// Adds both concept schemes (`sports`, `topics`) as taxonomy validations on the `article`
// content type, so the editor shows a Taxonomy tab and picks concepts from each. Not marked
// `required` — assignment is done by assign-concepts.js, and we don't want to block editing.
//
// Requires the schemes to exist first (run taxonomy:create). Concepts/schemes themselves
// can't be created via contentful-migration — only referenced as validations here.
//
// Env: CONTENTFUL_SPACE, CONTENTFUL_MANAGEMENT_TOKEN, CONTENTFUL_ENVIRONMENT (default master).
// Run: `npm run taxonomy:validate-article`. Revert: `npm run taxonomy:validate-article:revert`.

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
