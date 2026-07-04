// Inverse of remove-tags.js: rebuilds each `article` entry's `metadata.tags` from its
// assigned concepts. Only the 18 original topic tags are restored — race concepts never
// existed as tags, and the `races` parent was never assigned to entries — so they're
// skipped. Restores tag order from concept order. (Restoring the tag *definitions* in the
// space, if they were deleted, must be done first / manually.)
//
// Env: same as remove-tags.js (DRY_RUN, ENTRY_ID, CONTENTFUL_ENVIRONMENT).
// Run: `npm run taxonomy:restore-tags`.

const { LOCALE, TOPICS, paginateAll, createPlainClient, readEnv } = require('./lib/taxonomy');

const WRITE_DELAY_MS = 200;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The concept ids that map back to real metadata tags (every topic except the `races` root).
const TAG_IDS = new Set(TOPICS.filter((t) => t.id !== 'races').map((t) => t.id));

const tagLink = (id) => ({ sys: { type: 'Link', linkType: 'Tag', id } });

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

  let restored = 0;
  let published = 0;
  let unchanged = 0;
  let warned = 0;

  for (const entry of articles) {
    if (onlyId && entry.sys.id !== onlyId) continue;

    // Merge: keep whatever tags the entry still has (e.g. the preserved private `short`) and
    // add back the topic tags from its concepts that aren't already present. Race concepts
    // never existed as tags, so TAG_IDS excludes them.
    const haveTagIds = (entry.metadata?.tags || []).map((t) => t.sys.id);
    const topicIds = (entry.metadata?.concepts || []).map((c) => c.sys.id).filter((id) => TAG_IDS.has(id));
    const wantTagIds = [...haveTagIds, ...topicIds.filter((id) => !haveTagIds.includes(id))];

    if (JSON.stringify(wantTagIds) === JSON.stringify(haveTagIds)) {
      unchanged += 1;
      continue;
    }

    const title = entry.fields?.title?.[LOCALE] || '(untitled)';
    console.log(`~ ${entry.sys.id} "${title}"  restoring tags: ${wantTagIds.join(', ') || '(none)'}`);
    restored += 1;
    if (dryRun) continue;

    const wasPublished = typeof entry.sys.publishedVersion === 'number';
    const isClean = wasPublished && entry.sys.publishedVersion === entry.sys.version - 1;

    entry.metadata = { ...(entry.metadata || {}), tags: wantTagIds.map(tagLink) };
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
    `\n${dryRun ? '[DRY RUN] ' : ''}articles — tags restored: ${restored} (republished: ${published}, warned: ${warned}), unchanged: ${unchanged}`
  );
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
