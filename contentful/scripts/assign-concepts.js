// Assigns taxonomy concepts to every `article` entry's `metadata.concepts`, mirroring the
// migration's assignment rules:
//   1. Each of the entry's metadata TAGS maps 1:1 to the concept with the same id, in order
//      (tag ids and concept ids are identical — see create-taxonomy.js).
//   2. Race reports additionally get their RACE concept appended last: derived from the
//      linked `event` entry when present, else from the static article-slug → race map
//      (ARTICLE_RACE_MAP) for reports with no `event` link.
//
// Idempotent and safe to re-run: entries whose concepts already match are skipped (no
// version bump, no republish, no webhook). Publish state is preserved — a cleanly
// published entry is republished; an entry with unpublished draft changes is updated but
// NOT published (warned); a draft stays a draft.
//
// Env (contentful/.env):
//   CONTENTFUL_MANAGEMENT_TOKEN   CMA token (required)
//   CONTENTFUL_SPACE              space (required)
//   CONTENTFUL_ENVIRONMENT        environment (default: master) — entry assignment IS
//                                 environment-scoped, so rehearse on a sandbox first
//   DRY_RUN=true                  print per-entry plans, write nothing
//   ENTRY_ID=<sys.id>             restrict to a single entry (extra-safe trial)
//
// Run: `npm run taxonomy:assign` (dry-run: prefix DRY_RUN=true).

const {
  LOCALE,
  ARTICLE_RACE_MAP,
  slugify,
  conceptLink,
  getAllConcepts,
  paginateAll,
  createPlainClient,
  readEnv,
  EVENT_CONTENT_TYPE,
} = require('./lib/taxonomy');

const WRITE_DELAY_MS = 200;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// event sys.id → race concept id, so a linked event resolves to the right race concept.
async function eventConceptMap(client, { spaceId, environmentId }) {
  const events = await paginateAll((skip) =>
    client.entry.getMany({
      spaceId,
      environmentId,
      query: { content_type: EVENT_CONTENT_TYPE, skip, limit: 100, order: 'sys.createdAt' },
    })
  );
  const map = new Map();
  for (const event of events) {
    const title = event.fields?.title?.[LOCALE];
    if (title) map.set(event.sys.id, slugify(title));
  }
  return map;
}

// The concept ids an article should carry, in order: its tag ids (only those that have a
// matching concept — a tag with no concept, e.g. a legacy `short` marker, is skipped and
// recorded in `skipped`), then its race concept.
function desiredConceptIds(entry, eventConcepts, validIds, skipped) {
  const ids = [];
  for (const tag of entry.metadata?.tags || []) {
    if (validIds.has(tag.sys.id)) ids.push(tag.sys.id);
    else skipped.add(tag.sys.id);
  }
  const eventId = entry.fields?.event?.[LOCALE]?.sys?.id;
  const slug = entry.fields?.slug?.[LOCALE];
  const raceId = (eventId && eventConcepts.get(eventId)) || ARTICLE_RACE_MAP[slug];
  if (raceId && validIds.has(raceId) && !ids.includes(raceId)) ids.push(raceId);
  return ids;
}

async function run() {
  const { spaceId, environmentId, dryRun, onlyId } = readEnv();
  const client = createPlainClient();
  const eventConcepts = await eventConceptMap(client, { spaceId, environmentId });
  // The concept ids that actually exist (same source create-taxonomy.js used). Any tag id
  // outside this set has no concept and is skipped rather than assigned (which would 422).
  const validIds = new Set((await getAllConcepts(client, { spaceId, environmentId })).map((c) => c.id));
  const skipped = new Set();

  const articles = await paginateAll((skip) =>
    client.entry.getMany({
      spaceId,
      environmentId,
      query: { content_type: 'article', skip, limit: 100, order: 'sys.createdAt' },
    })
  );

  let updated = 0;
  let published = 0;
  let unchanged = 0;
  let warned = 0;

  for (const entry of articles) {
    if (onlyId && entry.sys.id !== onlyId) continue;

    const title = entry.fields?.title?.[LOCALE] || '(untitled)';
    const wantIds = desiredConceptIds(entry, eventConcepts, validIds, skipped);
    const haveIds = (entry.metadata?.concepts || []).map((c) => c.sys.id);

    // Skip-unchanged: same concepts, same order → leave the entry untouched.
    if (JSON.stringify(wantIds) === JSON.stringify(haveIds)) {
      unchanged += 1;
      continue;
    }

    console.log(`~ ${entry.sys.id} "${title}"\n    ${haveIds.join(', ') || '(none)'}  →  ${wantIds.join(', ')}`);
    updated += 1;
    if (dryRun) continue;

    // Determine publish intent from the ORIGINAL entry, before the update bumps version.
    const wasPublished = typeof entry.sys.publishedVersion === 'number';
    const isClean = wasPublished && entry.sys.publishedVersion === entry.sys.version - 1;

    entry.metadata = { ...(entry.metadata || {}), concepts: wantIds.map(conceptLink) };
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
    `\n${dryRun ? '[DRY RUN] ' : ''}articles — updated: ${updated} (republished: ${published}, left-as-draft/warned: ${warned}), unchanged: ${unchanged}`
  );

  if (skipped.size) {
    console.warn(
      `\n⚠ ${skipped.size} tag id(s) have no matching concept and were skipped (kept as legacy tags): ${[...skipped].sort().join(', ')}`
    );
    console.warn(
      '  If any of these should be concepts, add them to scripts/lib/taxonomy.js, re-run taxonomy:create, then taxonomy:assign again.'
    );
  }
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
