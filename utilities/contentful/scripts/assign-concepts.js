// Sets the `metadata.concepts` of each `article` entry from the ASSIGNMENTS map in lib/taxonomy.js.
// That map holds the most specific concepts of each scheme. This script adds each parent from the
// `broader` chain, with resolveAssignment, and writes the full path: the discipline, the distance,
// the race, and the topics.
//
// You can run it more than one time: it does nothing for an entry with no change, and the order of
// the concepts does not matter. It also keeps the publish state. It reports each article with no
// entry in ASSIGNMENTS, and each article with an unknown concept id, and it changes neither.
//
// The env vars: CONTENTFUL_SPACE, CONTENTFUL_MANAGEMENT_TOKEN, and CONTENTFUL_ENVIRONMENT, whose
// default is master.
//   DRY_RUN=true shows the plan for each entry. ENTRY_ID=<id> uses one entry only.
// To run it: `npm run taxonomy:assign`.

const { LOCALE, resolveAssignment, conceptLink, paginateAll, createPlainClient, readEnv } = require('./lib/taxonomy');

const WRITE_DELAY_MS = 200;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function run() {
  const { spaceId, environmentId, dryRun, onlyId } = readEnv();
  const client = createPlainClient();

  const articles = await paginateAll((skip) =>
    client.entry.getMany({ spaceId, environmentId, query: { content_type: 'article', skip, limit: 100, order: 'sys.createdAt' } })
  );

  let updated = 0, published = 0, unchanged = 0, warned = 0;
  const noAssignment = [];

  for (const entry of articles) {
    if (onlyId && entry.sys.id !== onlyId) continue;
    const slug = entry.fields?.slug?.[LOCALE];
    const title = entry.fields?.title?.[LOCALE] || '(untitled)';

    const unknown = [];
    const wantIds = slug ? resolveAssignment(slug, unknown) : null;
    if (wantIds === null) { noAssignment.push(slug || entry.sys.id); continue; }
    if (unknown.length) console.warn(`! ${slug}: unknown concept ids ${unknown.join(', ')} (skipped those)`);

    const haveIds = (entry.metadata?.concepts || []).map((c) => c.sys.id);
    if (JSON.stringify([...wantIds].sort()) === JSON.stringify([...haveIds].sort())) { unchanged += 1; continue; }

    console.log(`~ ${entry.sys.id} "${title}"\n    ${haveIds.sort().join(', ') || '(none)'}\n  → ${wantIds.join(', ')}`);
    updated += 1;
    if (dryRun) continue;

    const wasPublished = typeof entry.sys.publishedVersion === 'number';
    const isClean = wasPublished && entry.sys.publishedVersion === entry.sys.version - 1;
    entry.metadata = { ...(entry.metadata || {}), concepts: wantIds.map(conceptLink) };
    const saved = await client.entry.update({ spaceId, environmentId, entryId: entry.sys.id }, entry);

    if (isClean) { await client.entry.publish({ spaceId, environmentId, entryId: entry.sys.id }, saved); published += 1; }
    else if (wasPublished) { console.warn(`    ! ${entry.sys.id} has unpublished draft changes — updated but NOT republished`); warned += 1; }
    await sleep(WRITE_DELAY_MS);
  }

  console.log(`\n${dryRun ? '[DRY RUN] ' : ''}articles — updated: ${updated} (republished: ${published}, warned: ${warned}), unchanged: ${unchanged}`);
  if (noAssignment.length) console.warn(`⚠ ${noAssignment.length} article(s) have no ASSIGNMENTS entry (skipped): ${noAssignment.sort().join(', ')}`);
}

run().catch((err) => { console.error(err); process.exit(1); });
