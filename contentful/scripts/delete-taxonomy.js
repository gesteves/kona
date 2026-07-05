// Teardown: deletes EVERY concept scheme and concept currently in the org, so the new
// two-scheme taxonomy can be rebuilt fresh (create-taxonomy) with reused ids. REFUSES while
// any entry still links a concept — run `npm run taxonomy:unassign` first.
//
// Deletes schemes first (they reference concepts), then concepts deepest-first (by their live
// `broader`) so a parent is never removed while a child still points at it.
//
// ⚠️ This removes ALL taxonomy in the org. Fine for this single-project org; dry-run first.
// Env: CONTENTFUL_MANAGEMENT_TOKEN, CONTENTFUL_ORGANIZATION_ID, CONTENTFUL_SPACE. DRY_RUN=true.
// Run: `npm run taxonomy:delete`.

const { getExistingConcepts, getExistingSchemes, createPlainClient, readEnv } = require('./lib/taxonomy');

// Depth of a live concept following its first `broader` link up the (live) tree.
function depthOf(id, parentOf) {
  let depth = 0, cur = id, seen = new Set();
  while (parentOf.get(cur) && !seen.has(cur)) { seen.add(cur); depth += 1; cur = parentOf.get(cur); if (depth > 20) break; }
  return depth;
}

async function run() {
  const { organizationId, spaceId, environmentId, dryRun } = readEnv({ requireOrg: true });
  const client = createPlainClient();

  const concepts = await getExistingConcepts(client, { organizationId });
  const schemes = await getExistingSchemes(client, { organizationId });
  if (concepts.length === 0 && schemes.length === 0) { console.log('Nothing to delete — org taxonomy is empty.'); return; }

  // Safety: refuse if any entry still links a concept we're about to delete.
  const ids = concepts.map((c) => c.sys.id);
  if (ids.length) {
    const inUse = await client.entry.getMany({ spaceId, environmentId, query: { 'metadata.concepts.sys.id[in]': ids.join(','), limit: 1 } });
    if (inUse.total > 0) {
      console.error(`Refusing to delete: ${inUse.total} entr${inUse.total === 1 ? 'y' : 'ies'} still link a concept. Run taxonomy:unassign first.`);
      process.exit(1);
    }
  }

  // Delete all schemes first.
  for (const scheme of schemes) {
    console.log(`- delete scheme ${scheme.sys.id}`);
    if (!dryRun) await client.conceptScheme.delete({ organizationId, conceptSchemeId: scheme.sys.id, version: scheme.sys.version });
  }

  // Delete concepts deepest-first.
  const parentOf = new Map(concepts.map((c) => [c.sys.id, c.broader?.[0]?.sys?.id || null]));
  const ordered = [...concepts].sort((a, b) => depthOf(b.sys.id, parentOf) - depthOf(a.sys.id, parentOf));
  for (const c of ordered) {
    console.log(`- delete concept ${c.sys.id}`);
    if (!dryRun) await client.concept.delete({ organizationId, conceptId: c.sys.id, version: c.sys.version });
  }

  console.log(`\n${dryRun ? '[DRY RUN] ' : ''}deleted ${schemes.length} scheme(s) + ${concepts.length} concept(s).`);
}

run().catch((err) => { console.error(err); process.exit(1); });
