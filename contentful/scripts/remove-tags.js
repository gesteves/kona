// PHASE 5 cleanup — run only after concepts are assigned, both apps read them in
// production, and you've verified everything. Removes the metadata tags that were migrated
// to concepts from every `article` entry, while PRESERVING any tag that has no matching
// concept — e.g. the private `short` editorial marker, which stays for in-editor
// categorization. (contentful-migration can't touch metadata, so this uses the plain CMA
// client, like assign-concepts.js.) Deleting the migrated tag *definitions* in the space is
// a separate manual final step (blocked while any entry still references them).
//
// Skip-unchanged + publish-state preservation, same as assign-concepts.js. This is a
// second republish of the affected entries — expect the same sitemap/feed/webhook churn.
//
// Env: same as assign-concepts.js (DRY_RUN, ENTRY_ID, CONTENTFUL_ENVIRONMENT).
// Run: `npm run taxonomy:remove-tags`. Inverse: `npm run taxonomy:restore-tags`.

const { LOCALE, getAllConcepts, paginateAll, createPlainClient, readEnv } = require('./lib/taxonomy');

const WRITE_DELAY_MS = 200;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function run() {
  const { spaceId, environmentId, dryRun, onlyId } = readEnv();
  const client = createPlainClient();
  // Only tags that became concepts are removed; every other tag (e.g. private `short`) stays.
  const migratedIds = new Set((await getAllConcepts(client, { spaceId, environmentId })).map((c) => c.id));

  const articles = await paginateAll((skip) =>
    client.entry.getMany({
      spaceId,
      environmentId,
      query: { content_type: 'article', skip, limit: 100, order: 'sys.createdAt' },
    })
  );

  let cleared = 0;
  let published = 0;
  let unchanged = 0;
  let warned = 0;
  const preserved = new Set();

  for (const entry of articles) {
    if (onlyId && entry.sys.id !== onlyId) continue;

    const tags = entry.metadata?.tags || [];
    const toRemove = tags.filter((t) => migratedIds.has(t.sys.id)).map((t) => t.sys.id);
    const keep = tags.filter((t) => !migratedIds.has(t.sys.id));
    keep.forEach((t) => preserved.add(t.sys.id));

    if (toRemove.length === 0) {
      unchanged += 1;
      continue;
    }

    const title = entry.fields?.title?.[LOCALE] || '(untitled)';
    const kept = keep.map((t) => t.sys.id);
    console.log(`~ ${entry.sys.id} "${title}"  removing: ${toRemove.join(', ')}${kept.length ? `  keeping: ${kept.join(', ')}` : ''}`);
    cleared += 1;
    if (dryRun) continue;

    const wasPublished = typeof entry.sys.publishedVersion === 'number';
    const isClean = wasPublished && entry.sys.publishedVersion === entry.sys.version - 1;

    entry.metadata = { ...(entry.metadata || {}), tags: keep };
    const saved = await client.entry.update({ spaceId, environmentId, entryId: entry.sys.id }, entry);

    if (isClean) {
      await client.entry.publish({ spaceId, environmentId, entryId: entry.sys.id }, saved);
      published += 1;
    } else if (wasPublished) {
      console.warn(`    ! ${entry.sys.id} has unpublished draft changes — updated but NOT republished`);
      warned += 1;
    }
    await sleep(WRITE_DELAY_MS);
  }

  console.log(
    `\n${dryRun ? '[DRY RUN] ' : ''}articles — tags removed on: ${cleared} (republished: ${published}, warned: ${warned}), unchanged: ${unchanged}`
  );
  if (preserved.size) {
    console.log(`  preserved non-concept tags (kept for editorial use): ${[...preserved].sort().join(', ')}`);
  }
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
