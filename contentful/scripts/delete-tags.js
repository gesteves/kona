// PHASE 5 final cleanup — deletes the migrated metadata **tag definitions** from the space,
// now that entries carry taxonomy concepts instead. Run only after taxonomy:remove-tags has
// stripped these tags from every entry (a tag that's still referenced can't be deleted).
//
// Preserves the private `short` editorial tag. Defensively, any tag that ISN'T one we migrated
// is left alone and reported, so nothing unexpected is deleted — review the DRY_RUN list, and
// if some other tag should go too, add it below. Deletes that fail (e.g. a tag still in use)
// are caught and reported rather than aborting the run.
//
// ⚠️ There's no clean inverse — recreating a tag definition doesn't restore its entry links.
// The `npm run backup` space export is the safety net.
//
// Env: CONTENTFUL_MANAGEMENT_TOKEN, CONTENTFUL_SPACE, CONTENTFUL_ENVIRONMENT (default master).
//   DRY_RUN=true lists what would be deleted, writes nothing.
// Run: `npm run taxonomy:delete-tags`.

const { TOPICS, paginateAll, createPlainClient, readEnv } = require('./lib/taxonomy');

// The tags that were migrated to concepts: every topic id except the concept-only `races`
// parent (which never existed as a tag). Race concepts were never tags either.
const MIGRATED_TAG_IDS = new Set(TOPICS.filter((t) => t.id !== 'races').map((t) => t.id));

// Tags to keep regardless — private/editorial tags that aren't part of the public taxonomy.
const KEEP = new Set(['short']);

async function run() {
  const { spaceId, environmentId, dryRun } = readEnv();
  const client = createPlainClient();

  const tags = await paginateAll((skip) =>
    client.tag.getMany({ spaceId, environmentId, query: { skip, limit: 100 } })
  );

  let deleted = 0;
  const kept = [];
  const untouched = [];
  const failed = [];

  for (const tag of tags) {
    const id = tag.sys.id;
    if (KEEP.has(id)) {
      kept.push(id);
      continue;
    }
    if (!MIGRATED_TAG_IDS.has(id)) {
      untouched.push(id);
      continue;
    }

    console.log(`- delete tag ${id} ("${tag.name}")`);
    deleted += 1;
    if (dryRun) continue;
    try {
      await client.tag.delete({ spaceId, environmentId, tagId: id, version: tag.sys.version });
    } catch (err) {
      failed.push(id);
      console.warn(`  ! could not delete ${id}: ${err.message || err} (still referenced by an entry?)`);
    }
  }

  console.log(`\n${dryRun ? '[DRY RUN] ' : ''}tags — deleted: ${deleted}${failed.length ? `, failed: ${failed.length}` : ''}`);
  if (kept.length) console.log(`  kept (private/editorial): ${kept.sort().join(', ')}`);
  if (untouched.length) console.warn(`  left alone (not a migrated tag — add to the script if you want it gone): ${untouched.sort().join(', ')}`);
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
