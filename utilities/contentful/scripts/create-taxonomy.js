// Creates / reconciles the two concept schemes (`sports`, `topics`) and all their concepts
// from lib/taxonomy.js. Idempotent: creates what's missing, patches drifted prefLabel/broader,
// skips matches. Only touches prefLabel + broader — descriptions/altLabels are written by
// taxonomy:describe, so this won't clobber them on re-run.
//
// ⚠️ Concepts and schemes are ORG-LEVEL and permanent-ish. Dry-run first.
// Env: CONTENTFUL_MANAGEMENT_TOKEN, CONTENTFUL_ORGANIZATION_ID. DRY_RUN=true = plan only.
// Run: `npm run taxonomy:create`.

const {
  LOCALE, SCHEMES, CONCEPTS, conceptsForScheme,
  getExistingConcepts, getExistingSchemes, conceptLink, linkedIds, createPlainClient, readEnv,
} = require('./lib/taxonomy');

async function run() {
  const { organizationId, dryRun } = readEnv({ requireOrg: true });
  const client = createPlainClient();

  const existing = new Map((await getExistingConcepts(client, { organizationId })).map((c) => [c.sys.id, c]));
  let created = 0, patched = 0, skipped = 0;

  for (const concept of CONCEPTS) {
    const broaderLinks = concept.broader ? [conceptLink(concept.broader)] : [];
    const current = existing.get(concept.id);

    if (!current) {
      console.log(`+ concept ${concept.id} ("${concept.name}")${concept.broader ? ` ⊂ ${concept.broader}` : ''}`);
      created += 1;
      if (!dryRun) {
        await client.concept.createWithId(
          { organizationId, conceptId: concept.id },
          { prefLabel: { [LOCALE]: concept.name }, broader: broaderLinks }
        );
      }
      continue;
    }

    const ops = [];
    if (current.prefLabel?.[LOCALE] !== concept.name) ops.push({ op: 'replace', path: `/prefLabel/${LOCALE}`, value: concept.name });
    if (JSON.stringify(linkedIds(current.broader)) !== JSON.stringify(linkedIds(broaderLinks))) ops.push({ op: 'replace', path: '/broader', value: broaderLinks });
    if (ops.length === 0) { skipped += 1; continue; }
    console.log(`~ concept ${concept.id}: ${ops.map((o) => o.path).join(', ')}`);
    patched += 1;
    if (!dryRun) await client.concept.patch({ organizationId, conceptId: concept.id, version: current.sys.version }, ops);
  }

  // Reconcile each scheme's membership.
  const existingSchemes = new Map((await getExistingSchemes(client, { organizationId })).map((s) => [s.sys.id, s]));
  for (const scheme of SCHEMES) {
    const inScheme = conceptsForScheme(scheme.id);
    const topConcepts = inScheme.filter((c) => !c.broader).map((c) => conceptLink(c.id));
    const concepts = inScheme.map((c) => conceptLink(c.id));
    const current = existingSchemes.get(scheme.id);

    if (!current) {
      console.log(`+ scheme ${scheme.id} ("${scheme.name}") — ${concepts.length} concepts`);
      if (!dryRun) {
        await client.conceptScheme.createWithId(
          { organizationId, conceptSchemeId: scheme.id },
          { prefLabel: { [LOCALE]: scheme.name }, topConcepts, concepts }
        );
      }
      continue;
    }
    const ops = [];
    if (JSON.stringify(linkedIds(current.topConcepts)) !== JSON.stringify(linkedIds(topConcepts))) ops.push({ op: 'replace', path: '/topConcepts', value: topConcepts });
    if (JSON.stringify(linkedIds(current.concepts)) !== JSON.stringify(linkedIds(concepts))) ops.push({ op: 'replace', path: '/concepts', value: concepts });
    if (ops.length === 0) { console.log(`= scheme ${scheme.id} up to date`); continue; }
    console.log(`~ scheme ${scheme.id}: ${ops.map((o) => o.path).join(', ')}`);
    if (!dryRun) await client.conceptScheme.patch({ organizationId, conceptSchemeId: scheme.id, version: current.sys.version }, ops);
  }

  console.log(`\n${dryRun ? '[DRY RUN] ' : ''}concepts — created: ${created}, patched: ${patched}, unchanged: ${skipped}, total: ${CONCEPTS.length}`);
}

run().catch((err) => { console.error(err); process.exit(1); });
