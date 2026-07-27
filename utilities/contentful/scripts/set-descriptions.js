// Writes each concept's `definition` (archive-page description) and `altLabels` (synonyms)
// from the CONCEPTS list in lib/taxonomy.js. Idempotent, skip-unchanged, DRY_RUN. Patches only
// definition/altLabels, so it never disturbs prefLabel/broader (create-taxonomy owns those).
//
// Env: CONTENTFUL_MANAGEMENT_TOKEN, CONTENTFUL_ORGANIZATION_ID. DRY_RUN=true = plan only.
// Run: `npm run taxonomy:describe`.

const { LOCALE, CONCEPTS, getExistingConcepts, createPlainClient, readEnv } = require('./lib/taxonomy');

const sameArray = (a, b) => JSON.stringify(a || []) === JSON.stringify(b || []);

async function run() {
  const { organizationId, dryRun } = readEnv({ requireOrg: true });
  const client = createPlainClient();
  const existing = new Map((await getExistingConcepts(client, { organizationId })).map((c) => [c.sys.id, c]));

  let updated = 0, unchanged = 0;
  const missing = [];

  for (const concept of CONCEPTS) {
    const current = existing.get(concept.id);
    if (!current) { missing.push(concept.id); continue; }

    const ops = [];
    const desc = concept.description || null;
    if ((current.definition?.[LOCALE] || null) !== desc) ops.push({ op: 'add', path: '/definition', value: desc ? { [LOCALE]: desc } : null });
    const alts = concept.altLabels || [];
    if (!sameArray(current.altLabels?.[LOCALE], alts)) ops.push({ op: 'add', path: '/altLabels', value: { [LOCALE]: alts } });

    if (ops.length === 0) { unchanged += 1; continue; }
    console.log(`~ ${concept.id}: ${ops.map((o) => o.path).join(', ')}`);
    updated += 1;
    if (!dryRun) await client.concept.patch({ organizationId, conceptId: concept.id, version: current.sys.version }, ops);
  }

  console.log(`\n${dryRun ? '[DRY RUN] ' : ''}concepts — copy updated: ${updated}, unchanged: ${unchanged}`);
  if (missing.length) console.warn(`⚠ ${missing.length} concept(s) not created yet (run taxonomy:create first): ${missing.sort().join(', ')}`);
}

run().catch((err) => { console.error(err); process.exit(1); });
