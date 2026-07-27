// Inverse of assign-concepts.js: clears `metadata.concepts` on every `article` entry
// (back to []). Same mechanics — skip-unchanged (entries with no concepts are left alone)
// and publish-state preservation. Run this before taxonomy:delete, which refuses to run
// while any entry still links a concept.
//
// Env: same as assign-concepts.js (DRY_RUN, ENTRY_ID, CONTENTFUL_ENVIRONMENT).
// Run: `npm run taxonomy:unassign`.

const { LOCALE, paginateAll, createPlainClient, readEnv } = require('./lib/taxonomy');

const WRITE_DELAY_MS = 200;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function run() {
  const { spaceId, environmentId, dryRun, onlyId } = readEnv();
  const client = createPlainClient();

  const articles = await paginateAll((skip) =>
    client.entry.getMany({
      spaceId,
      environmentId,
      query: { content_type: 'article', skip, limit: 100, order: 'sys.createdAt' },
    })
  );

  let cleared = 0;
  let published = 0;
  let skipped = 0;
  let warned = 0;

  for (const entry of articles) {
    if (onlyId && entry.sys.id !== onlyId) continue;

    const haveIds = (entry.metadata?.concepts || []).map((c) => c.sys.id);
    if (haveIds.length === 0) {
      skipped += 1;
      continue;
    }

    const title = entry.fields?.title?.[LOCALE] || '(untitled)';
    console.log(`~ ${entry.sys.id} "${title}"  clearing: ${haveIds.join(', ')}`);
    cleared += 1;
    if (dryRun) continue;

    const wasPublished = typeof entry.sys.publishedVersion === 'number';
    const isClean = wasPublished && entry.sys.publishedVersion === entry.sys.version - 1;

    entry.metadata = { ...(entry.metadata || {}), concepts: [] };
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
    `\n${dryRun ? '[DRY RUN] ' : ''}articles — cleared: ${cleared} (republished: ${published}, warned: ${warned}), unchanged: ${skipped}`
  );
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
