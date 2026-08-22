// Copies the space into a JSON backup file with a timestamp, before a migration that removes data.
// It calls the `space export` of contentful-cli, thus that command reads each CONTENTFUL_* var from
// .env, as each other script here does with `node --env-file=.env`, and you do not need those vars
// in your shell.
//
// It writes contentful-export-<space>-<env>-<timestamp>.json into this directory, and .gitignore
// contains that name.
// To run it: `npm run backup`. It uses CONTENTFUL_ENVIRONMENT, or master.
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
