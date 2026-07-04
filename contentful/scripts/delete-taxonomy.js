// Inverse of create-taxonomy.js: deletes the `topics` concept scheme and every concept
// it manages (topics + races). REFUSES to run while any entry still links one of these
// concepts — run `npm run taxonomy:unassign` first.
//
// Deletes the scheme first (it references all concepts), then concepts deepest-first so a
// parent is never removed while a child still points at it via `broader`.
//
// Env: same as create-taxonomy.js. `DRY_RUN=true` prints the plan and writes nothing.
// Run: `npm run taxonomy:delete`.

const {
  SCHEME,
  getAllConcepts,
  getExistingConcepts,
  createPlainClient,
  readEnv,
} = require('./lib/taxonomy');

// Depth of a concept in the desired set (roots = 0), following `broader` up the tree.
function depthOf(concept, byId) {
  let depth = 0;
  let cur = concept;
  while (cur && cur.broader) {
    depth += 1;
    cur = byId.get(cur.broader);
    if (depth > 10) break; // guard against a cycle
  }
  return depth;
}

async function run() {
  const { organizationId, spaceId, environmentId, dryRun } = readEnv({ requireOrg: true });
  const client = createPlainClient();

  const desired = await getAllConcepts(client, { spaceId, environmentId });
  const desiredIds = new Set(desired.map((c) => c.id));

  // Safety: bail if any entry still links a concept we're about to delete.
  const inUse = await client.entry.getMany({
    spaceId,
    environmentId,
    query: {
      'metadata.concepts.sys.id[in]': [...desiredIds].join(','),
      limit: 1,
    },
  });
  if (inUse.total > 0) {
    console.error(
      `Refusing to delete: ${inUse.total} entr${inUse.total === 1 ? 'y' : 'ies'} still link these concepts. Run taxonomy:unassign first.`
    );
    process.exit(1);
  }

  const existing = await getExistingConcepts(client, { organizationId });
  const existingById = new Map(existing.map((c) => [c.sys.id, c]));
  const desiredById = new Map(desired.map((c) => [c.id, c]));

  // Delete the scheme first.
  const schemeList = await client.conceptScheme.getMany({ organizationId, query: {} });
  const currentScheme = schemeList.items.find((s) => s.sys.id === SCHEME.id);
  if (currentScheme) {
    console.log(`- delete scheme ${SCHEME.id}`);
    if (!dryRun) {
      await client.conceptScheme.delete({
        organizationId,
        conceptSchemeId: SCHEME.id,
        version: currentScheme.sys.version,
      });
    }
  } else {
    console.log(`= scheme ${SCHEME.id} already absent`);
  }

  // Delete concepts deepest-first.
  const toDelete = desired
    .filter((c) => existingById.has(c.id))
    .sort((a, b) => depthOf(b, desiredById) - depthOf(a, desiredById));

  let deleted = 0;
  for (const concept of toDelete) {
    const current = existingById.get(concept.id);
    console.log(`- delete concept ${concept.id}`);
    deleted += 1;
    if (!dryRun) {
      await client.concept.delete({
        organizationId,
        conceptId: concept.id,
        version: current.sys.version,
      });
    }
  }

  console.log(`\n${dryRun ? '[DRY RUN] ' : ''}deleted ${deleted} concept(s)${currentScheme ? ' + 1 scheme' : ''}.`);
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
