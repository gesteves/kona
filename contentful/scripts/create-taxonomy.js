// Creates / reconciles the `topics` concept scheme and its concepts (the 18 topic
// concepts mirroring the old metadata tags + a `races` branch with one concept per race).
// Idempotent: run it again after adding races/events and it only creates what's missing
// and patches what drifted, skipping everything already correct.
//
// ⚠️ Concepts and schemes are ORG-LEVEL and permanent-ish — there is no environment
// sandbox for them, and their ids become load-bearing (`/tagged/<id>` URLs). Dry-run
// first and read the plan before applying.
//
// Env (contentful/.env, loaded by `node --env-file`):
//   CONTENTFUL_MANAGEMENT_TOKEN   CMA token (required)
//   CONTENTFUL_ORGANIZATION_ID    org that owns the taxonomy (required)
//   CONTENTFUL_SPACE              space to read `event` entries from (required)
//   CONTENTFUL_ENVIRONMENT        environment to read events from (default: master)
//   DRY_RUN=true                  print the plan, write nothing
//
// Run: `npm run taxonomy:create` (dry-run: prefix DRY_RUN=true).
//
// Note on prefLabels: the topic prefLabels MUST stay equal to the old tag names — the
// feed <category>, Open Graph article:tag, JSON-LD keywords/articleSection, and
// share_helpers.rb all read these names. Descriptions (`definition`) and synonyms
// (`altLabels`) are intentionally left for you to fill in via the Taxonomy manager;
// this script never writes or clobbers them (it patches only prefLabel/broader).

const {
  LOCALE,
  SCHEME,
  getAllConcepts,
  getExistingConcepts,
  conceptLink,
  linkedIds,
  createPlainClient,
  readEnv,
} = require('./lib/taxonomy');

async function run() {
  const { organizationId, spaceId, environmentId, dryRun } = readEnv({ requireOrg: true });
  const client = createPlainClient();

  const desired = await getAllConcepts(client, { spaceId, environmentId });
  const existing = await getExistingConcepts(client, { organizationId });
  const existingById = new Map(existing.map((c) => [c.sys.id, c]));

  let created = 0;
  let patched = 0;
  let skipped = 0;

  for (const concept of desired) {
    const broaderLinks = concept.broader ? [conceptLink(concept.broader)] : [];
    const current = existingById.get(concept.id);

    if (!current) {
      console.log(`+ create concept ${concept.id} ("${concept.name}")${concept.broader ? ` ⊂ ${concept.broader}` : ''}`);
      created += 1;
      if (!dryRun) {
        await client.concept.createWithId(
          { organizationId, conceptId: concept.id },
          { prefLabel: { [LOCALE]: concept.name }, broader: broaderLinks }
        );
      }
      continue;
    }

    // Reconcile only prefLabel + broader via JSON Patch so any definition/altLabels a
    // human added in the Taxonomy manager survive re-runs.
    const ops = [];
    if (current.prefLabel?.[LOCALE] !== concept.name) {
      ops.push({ op: 'replace', path: `/prefLabel/${LOCALE}`, value: concept.name });
    }
    const wantBroader = linkedIds(broaderLinks);
    if (JSON.stringify(linkedIds(current.broader)) !== JSON.stringify(wantBroader)) {
      ops.push({ op: 'replace', path: '/broader', value: broaderLinks });
    }

    if (ops.length === 0) {
      skipped += 1;
      continue;
    }
    console.log(`~ patch concept ${concept.id}: ${ops.map((o) => o.path).join(', ')}`);
    patched += 1;
    if (!dryRun) {
      await client.concept.patch(
        { organizationId, conceptId: concept.id, version: current.sys.version },
        ops
      );
    }
  }

  // Reconcile the scheme: topConcepts = the roots (no broader), concepts = all of them.
  const topConcepts = desired.filter((c) => !c.broader).map((c) => conceptLink(c.id));
  const concepts = desired.map((c) => conceptLink(c.id));
  const schemeList = await client.conceptScheme.getMany({ organizationId, query: {} });
  const currentScheme = schemeList.items.find((s) => s.sys.id === SCHEME.id);

  if (!currentScheme) {
    console.log(`+ create scheme ${SCHEME.id} ("${SCHEME.name}") with ${concepts.length} concepts`);
    if (!dryRun) {
      await client.conceptScheme.createWithId(
        { organizationId, conceptSchemeId: SCHEME.id },
        { prefLabel: { [LOCALE]: SCHEME.name }, topConcepts, concepts }
      );
    }
  } else {
    const ops = [];
    if (JSON.stringify(linkedIds(currentScheme.topConcepts)) !== JSON.stringify(linkedIds(topConcepts))) {
      ops.push({ op: 'replace', path: '/topConcepts', value: topConcepts });
    }
    if (JSON.stringify(linkedIds(currentScheme.concepts)) !== JSON.stringify(linkedIds(concepts))) {
      ops.push({ op: 'replace', path: '/concepts', value: concepts });
    }
    if (ops.length === 0) {
      console.log(`= scheme ${SCHEME.id} already up to date`);
    } else {
      console.log(`~ patch scheme ${SCHEME.id}: ${ops.map((o) => o.path).join(', ')}`);
      if (!dryRun) {
        await client.conceptScheme.patch(
          { organizationId, conceptSchemeId: SCHEME.id, version: currentScheme.sys.version },
          ops
        );
      }
    }
  }

  console.log(
    `\n${dryRun ? '[DRY RUN] ' : ''}concepts — created: ${created}, patched: ${patched}, unchanged: ${skipped}, total desired: ${desired.length}`
  );
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
