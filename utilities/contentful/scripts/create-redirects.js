// Makes or updates a 301 `redirect` entry for each archive URL that moves in the two-scheme
// redesign. Thus an old /tagged/* link still works. The old paths come from web/data/tags.json, thus
// ⚠️ run this BEFORE the next import. You can run it more than one time: it matches on `from` and it
// does not change another redirect.
//
// The env vars: CONTENTFUL_SPACE, CONTENTFUL_MANAGEMENT_TOKEN, CONTENTFUL_ENVIRONMENT, and DRY_RUN.
// To run it: `npm run taxonomy:redirects`.

const fs = require('fs');
const path = require('path');
const { LOCALE, CONCEPTS, expandAncestors, paginateAll, createPlainClient, readEnv } = require('./lib/taxonomy');

// Each old concept id, and the new concept whose page is the best replacement for it.
const RETIRED = { ironman: 'full-distance', 'ironman-703': 'half-distance', olympic: 'olympic-distance', races: 'race-reports' };

const newPath = (id) => `/tagged/${expandAncestors(id).reverse().join('/')}/`;

function buildRedirects() {
  const tagsPath = path.resolve(__dirname, '../../../web/data/tags.json');
  const oldPaths = new Map();
  JSON.parse(fs.readFileSync(tagsPath, 'utf8')).forEach((t) => oldPaths.set(t.tag.id, t.tag.path));

  const seen = new Set();
  const redirects = [];
  const add = (from, to) => { if (from && to && from !== to && !seen.has(from)) { seen.add(from); redirects.push({ from, to }); } };

  for (const c of CONCEPTS) add(oldPaths.get(c.id), newPath(c.id));
  for (const [oldId, newId] of Object.entries(RETIRED)) add(oldPaths.get(oldId), newPath(newId));
  return redirects;
}

async function run() {
  const { spaceId, environmentId, dryRun } = readEnv();
  const client = createPlainClient();
  const redirects = buildRedirects();

  const existing = await paginateAll((skip) =>
    client.entry.getMany({ spaceId, environmentId, query: { content_type: 'redirect', skip, limit: 100 } })
  );
  const byFrom = new Map(existing.map((e) => [e.fields?.from?.[LOCALE], e]));

  let created = 0, updated = 0, unchanged = 0;
  for (const { from, to } of redirects) {
    const entry = byFrom.get(from);
    if (!entry) {
      console.log(`+ redirect ${from} → ${to}`);
      created += 1;
      if (!dryRun) {
        const e = await client.entry.create({ spaceId, environmentId, contentTypeId: 'redirect' },
          { fields: { from: { [LOCALE]: from }, to: { [LOCALE]: to }, status: { [LOCALE]: 301 } } });
        await client.entry.publish({ spaceId, environmentId, entryId: e.sys.id }, e);
      }
      continue;
    }
    if (entry.fields?.to?.[LOCALE] === to) { unchanged += 1; continue; }
    console.log(`~ redirect ${from} → ${to} (was ${entry.fields?.to?.[LOCALE]})`);
    updated += 1;
    if (!dryRun) {
      entry.fields.to = { [LOCALE]: to };
      const saved = await client.entry.update({ spaceId, environmentId, entryId: entry.sys.id }, entry);
      await client.entry.publish({ spaceId, environmentId, entryId: entry.sys.id }, saved);
    }
  }

  console.log(`\n${dryRun ? '[DRY RUN] ' : ''}redirects — created: ${created}, updated: ${updated}, unchanged: ${unchanged}`);
}

run().catch((err) => { console.error(err); process.exit(1); });
