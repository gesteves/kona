// Exports the space to a timestamped JSON backup before a destructive migration. Wraps the
// contentful-cli `space export` so it picks up CONTENTFUL_* from .env like every other script
// here (via `node --env-file=.env`), instead of requiring the vars in your shell.
//
// Writes contentful-export-<space>-<env>-<timestamp>.json into this directory (gitignored).
// Run: `npm run backup` (targets CONTENTFUL_ENVIRONMENT or master).
const { execFileSync } = require('child_process');

const spaceId = process.env.CONTENTFUL_SPACE;
const accessToken = process.env.CONTENTFUL_MANAGEMENT_TOKEN;
const environmentId = process.env.CONTENTFUL_ENVIRONMENT || 'master';

if (!spaceId || !accessToken) {
  console.error('Missing CONTENTFUL_SPACE and/or CONTENTFUL_MANAGEMENT_TOKEN — set them in contentful/.env.');
  process.exit(1);
}

execFileSync(
  'npx',
  [
    '--yes', 'contentful-cli', 'space', 'export',
    '--space-id', spaceId,
    '--management-token', accessToken,
    '--environment-id', environmentId,
  ],
  { stdio: 'inherit' }
);
