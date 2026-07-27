// One-off: writes the race/event concepts' `definition` (archive-page description) from the
// CONCEPTS list in lib/taxonomy.js. Deliberately scoped to the 17 event concepts listed below,
// and patches ONLY `/definition` — it never touches `altLabels`, and never touches any other
// concept. So descriptions edited directly in Contentful for the topic/distance/discipline
// concepts are left completely untouched (unlike `taxonomy:describe`, which reconciles every
// concept). Idempotent, skip-unchanged, DRY_RUN.
//
// Env: CONTENTFUL_MANAGEMENT_TOKEN, CONTENTFUL_ORGANIZATION_ID. DRY_RUN=true = plan only.
// Run: `npm run taxonomy:describe-events` (dry-run first: `DRY_RUN=true npm run taxonomy:describe-events`).

const { LOCALE, byId, getExistingConcepts, createPlainClient, readEnv } = require('./lib/taxonomy');

// The race/event concepts whose descriptions come from event-descriptions.md. Only these are
// touched; anything not in this list (topics, distances, disciplines) is ignored entirely.
const EVENT_IDS = [
  'ironman-canada',
  'ironman-coeur-dalene',
  'ironman-703-coeur-dalene',
  'ironman-703-boise',
  'ironman-703-washington-tri-cities',
  'ironman-703-st-george',
  'ironman-703-boulder',
  'ironman-703-arizona',
  'ironman-703-ruidoso-new-mexico',
  'gates-of-yellowstone-triathlon',
  'bozeman-triathlon',
  'escape-from-alcatraz-triathlon',
  'grand-teton-half-marathon',
  'jackson-hole-half-marathon',
  'hole-half-marathon',
  'carrera-san-silvestre-12k',
  'teton-mountain-runs-wild-15k',
];

async function run() {
  const { organizationId, dryRun } = readEnv({ requireOrg: true });
  const client = createPlainClient();
  const existing = new Map((await getExistingConcepts(client, { organizationId })).map((c) => [c.sys.id, c]));

  let updated = 0, unchanged = 0;
  const missing = [];

  for (const id of EVENT_IDS) {
    const concept = byId.get(id);
    if (!concept) { console.warn(`⚠ ${id} is not in lib/taxonomy.js — skipping`); continue; }

    const current = existing.get(id);
    if (!current) { missing.push(id); continue; }

    const desc = concept.description || null;
    if ((current.definition?.[LOCALE] || null) === desc) { unchanged += 1; continue; }

    console.log(`~ ${id}: /definition`);
    updated += 1;
    if (!dryRun) {
      await client.concept.patch(
        { organizationId, conceptId: id, version: current.sys.version },
        [{ op: 'add', path: '/definition', value: desc ? { [LOCALE]: desc } : null }],
      );
    }
  }

  console.log(`\n${dryRun ? '[DRY RUN] ' : ''}event descriptions — updated: ${updated}, unchanged: ${unchanged}`);
  if (missing.length) console.warn(`⚠ ${missing.length} concept(s) not found in Contentful: ${missing.sort().join(', ')}`);
}

run().catch((err) => { console.error(err); process.exit(1); });
