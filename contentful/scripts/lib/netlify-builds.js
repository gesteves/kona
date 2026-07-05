// Pause Netlify builds around a Contentful migration, then optionally trigger one deploy.
//
// Why: publishing entries fires Contentful webhooks that each kick off a Netlify build, so a
// migration touching many entries produces a storm of redundant deploys. Stopping builds for the
// duration collapses that to zero; at the end we re-activate and (after asking) trigger a single
// build that picks up everything at once. See contentful/CLAUDE.md ("paused-builds cutover").
//
// Wrap a migration's body with withBuildsPaused(fn):
//   await withBuildsPaused(() => runMigration({ ... }));
// It ALWAYS re-activates builds — on success, on throw, and on Ctrl-C — so the site can never be
// left frozen. On success it prompts "Trigger a deploy now?"; declining leaves builds active but
// idle (the next push/webhook deploys as usual).
//
// Config (contentful/.env):
//   NETLIFY_AUTH_TOKEN   Personal access token (Netlify → User settings → Applications).
//   NETLIFY_SITE_ID      The site's API ID (Site configuration → General → Site information).
// Honors DRY_RUN=true like the other scripts here: logs what it would do and touches nothing.
const readline = require('node:readline');

const API = 'https://api.netlify.com/api/v1';

function readConfig() {
  return {
    token: process.env.NETLIFY_AUTH_TOKEN,
    siteId: process.env.NETLIFY_SITE_ID,
    dryRun: process.env.DRY_RUN === 'true',
  };
}

async function netlify(method, path, body) {
  const { token } = readConfig();
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
    throw new Error(`Netlify ${method} ${path} → ${res.status} ${res.statusText}${detail ? `: ${detail}` : ''}`);
  }
  return res.status === 204 ? null : res.json().catch(() => null);
}

async function setStopBuilds(stopped) {
  const { siteId } = readConfig();
  await netlify('PATCH', `/sites/${siteId}`, { build_settings: { stop_builds: stopped } });
}

const stopBuilds = () => setStopBuilds(true);
const activateBuilds = () => setStopBuilds(false);

async function triggerBuild() {
  const { siteId } = readConfig();
  return netlify('POST', `/sites/${siteId}/builds`);
}

function promptYesNo(question) {
  return new Promise((resolve) => {
    // Non-interactive (piped/CI): default to "no" rather than hang waiting on stdin.
    if (!process.stdin.isTTY) {
      console.log(`${question} (no TTY → assuming no)`);
      resolve(false);
      return;
    }
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(`${question} [y/N] `, (answer) => {
      rl.close();
      resolve(/^y(es)?$/i.test(answer.trim()));
    });
  });
}

// Runs `fn` with Netlify builds paused. Re-activates builds no matter how `fn` ends, then — only
// on success — asks whether to trigger a single deploy. Returns whatever `fn` returns.
async function withBuildsPaused(fn) {
  const { token, siteId, dryRun } = readConfig();

  if (dryRun) {
    console.log('[dry-run] would stop Netlify builds, run the migration, re-activate, then prompt to deploy.');
    return fn();
  }

  if (!token || !siteId) {
    throw new Error('Missing NETLIFY_AUTH_TOKEN and/or NETLIFY_SITE_ID — set them in contentful/.env.');
  }

  // Ctrl-C safety: re-activate builds before exiting so an aborted migration never leaves the site frozen.
  let interrupted = false;
  const onSigint = () => {
    if (interrupted) return; // a second Ctrl-C forces exit
    interrupted = true;
    console.log('\nInterrupted — re-activating Netlify builds…');
    activateBuilds()
      .catch((e) => console.error(`Failed to re-activate builds: ${e.message} — do it manually in the Netlify UI.`))
      .finally(() => process.exit(130));
  };
  process.on('SIGINT', onSigint);

  console.log('Stopping Netlify builds for the migration…');
  await stopBuilds();

  try {
    const result = await fn();
    await activateBuilds();
    console.log('Netlify builds re-activated.');
    if (await promptYesNo('Trigger a deploy now?')) {
      await triggerBuild();
      console.log('Deploy triggered.');
    } else {
      console.log('Skipped — no deploy triggered (builds are active for the next push/webhook).');
    }
    return result;
  } catch (err) {
    await activateBuilds().catch((e) =>
      console.error(`Also failed to re-activate builds: ${e.message} — do it manually in the Netlify UI.`),
    );
    console.error('Migration failed — Netlify builds re-activated, skipping deploy prompt.');
    throw err;
  } finally {
    process.off('SIGINT', onSigint);
  }
}

module.exports = { withBuildsPaused, stopBuilds, activateBuilds, triggerBuild };
