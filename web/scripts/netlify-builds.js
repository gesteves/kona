// Quick CLI to stop / re-activate Netlify builds for this site, outside any migration — e.g. to
// hold deploys during a content freeze, or while pushing a burst of small commits. Also reports the
// current build status and can trigger a one-off deploy.
//
// Run via the npm scripts (they load web/.env with `node --env-file`):
//   npm run build:status     show whether builds are currently stopped or active
//   npm run build:stop       stop builds (no production deploys, Deploy Previews, or branch deploys)
//   npm run build:activate   re-activate builds (does NOT itself deploy; the next push/webhook does)
//   npm run build:deploy     trigger a single production build now
//
// Requires NETLIFY_AUTH_TOKEN + NETLIFY_SITE_ID in web/.env (see .env.example).
// Note: activating builds does not trigger one — run build:deploy if you want an immediate deploy.
const API = 'https://api.netlify.com/api/v1';

const token = process.env.NETLIFY_AUTH_TOKEN;
const siteId = process.env.NETLIFY_SITE_ID;

async function netlify(method, path, body) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    throw new Error(
      `Netlify ${method} ${path} → ${res.status} ${res.statusText}${detail ? `: ${detail}` : ''}`
    );
  }
  return res.status === 204 ? null : res.json().catch(() => null);
}

async function status() {
  const site = await netlify('GET', `/sites/${siteId}`);
  const stopped = site?.build_settings?.stop_builds;
  console.log(`Netlify builds are ${stopped ? 'STOPPED' : 'active'}.`);
}

async function setStopBuilds(stopped) {
  await netlify('PATCH', `/sites/${siteId}`, {
    build_settings: { stop_builds: stopped },
  });
  console.log(
    stopped ? 'Netlify builds stopped.' : 'Netlify builds re-activated.'
  );
}

async function deploy() {
  await netlify('POST', `/sites/${siteId}/builds`);
  console.log('Production build triggered.');
}

const commands = {
  status,
  stop: () => setStopBuilds(true),
  activate: () => setStopBuilds(false),
  deploy,
};

async function main() {
  const cmd = process.argv[2];
  const run = commands[cmd];
  if (!run) {
    console.error(
      `Usage: node scripts/netlify-builds.js <${Object.keys(commands).join('|')}>`
    );
    process.exit(1);
  }
  if (!token || !siteId) {
    console.error(
      'Missing NETLIFY_AUTH_TOKEN and/or NETLIFY_SITE_ID — set them in web/.env.'
    );
    process.exit(1);
  }
  await run();
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
