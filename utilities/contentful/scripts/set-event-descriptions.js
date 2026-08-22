// A script that runs one time: it writes the archive-page description of each race concept and each
// event concept, from lib/taxonomy.js. It applies to the event concepts in the list below only, on
// purpose, and it changes `/definition` only. Thus a description that a person edits in Contentful
// for each other concept stays the same. `taxonomy:describe` is different: it changes all of them.
// You can run this more than one time, and it does nothing for a concept with no change.
//
// The env vars: CONTENTFUL_MANAGEMENT_TOKEN, CONTENTFUL_ORGANIZATION_ID, and DRY_RUN.
// To run it: `npm run taxonomy:describe-events`.

const { LOCALE, byId, getExistingConcepts, createPlainClient, readEnv } = require('./lib/taxonomy');

// The race concepts and the event concepts whose descriptions come from event-descriptions.md. This
// script changes these concepts only. It ignores each concept that is not in this list: a topic, a
// distance, and a discipline.
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
