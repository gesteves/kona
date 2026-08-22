// A read-only review of the taxonomy in lib/taxonomy.js. It writes NOTHING to Contentful.
// It shows each concept, in a group for each scheme, with an indent for each level, and with its
// altLabels and its description. It also shows the full path of the concepts of each article, and it
// compares that with the web data from the build (web/data/articles.json). Thus you can see each
// article with no concepts and each concept that is old.
//
// To run it: `npm run taxonomy:preview`. Change lib/taxonomy.js, run it again, and continue until
// the result is correct.

const fs = require('fs');
const path = require('path');
const {
  SCHEMES, CONCEPTS, ASSIGNMENTS, byId, expandAncestors, resolveAssignment, conceptsForScheme,
} = require('./lib/taxonomy');

const name = (id) => byId.get(id)?.name || `⟨${id}⟩`;

function printConcepts() {
  console.log('═══ CONCEPTS ═══');
  for (const scheme of SCHEMES) {
    console.log(`\n### ${scheme.name} (${scheme.id})`);
    const concepts = conceptsForScheme(scheme.id);
    const roots = concepts.filter((c) => !c.broader);
    const childrenOf = (id) => concepts.filter((c) => c.broader === id);
    const walk = (c, depth) => {
      const indent = '  '.repeat(depth);
      const alt = c.altLabels?.length ? `  [${c.altLabels.join(', ')}]` : '';
      console.log(`${indent}• ${c.name} (${c.id})${alt}`);
      if (c.description) console.log(`${indent}    ${c.description}`);
      childrenOf(c.id).forEach((child) => walk(child, depth + 1));
    };
    roots.forEach((r) => walk(r, 0));
    console.log(`  — ${concepts.length} concepts`);
  }
}

function validate() {
  const problems = [];
  for (const c of CONCEPTS) {
    if (c.broader && !byId.has(c.broader)) problems.push(`concept ${c.id}: unknown broader "${c.broader}"`);
    if (c.broader && byId.get(c.broader).scheme !== c.scheme) problems.push(`concept ${c.id}: broader "${c.broader}" is in a different scheme`);
  }
  return problems;
}

function printAssignments(publishedSlugs) {
  console.log('\n═══ ASSIGNMENTS ═══');
  const unknownIds = new Set();
  for (const slug of Object.keys(ASSIGNMENTS).sort()) {
    const unknown = [];
    const ids = resolveAssignment(slug, unknown);
    unknown.forEach((u) => unknownIds.add(u));
    const flag = publishedSlugs && !publishedSlugs.has(slug) ? '  ⚠ not a published slug' : '';
    console.log(`\n${slug}${flag}`);
    console.log(`  → ${ids.map(name).join(' · ') || '(none)'}`);
    if (unknown.length) console.log(`  ⚠ unknown ids: ${unknown.join(', ')}`);
  }
  return unknownIds;
}

function main() {
  printConcepts();

  let publishedSlugs = null;
  const articlesPath = path.resolve(__dirname, '../../../web/data/articles.json');
  try {
    const arts = JSON.parse(fs.readFileSync(articlesPath, 'utf8')).filter((a) => !a.draft);
    publishedSlugs = new Set(arts.map((a) => a.slug));
  } catch {
    console.log('\n(could not read web/data/articles.json — skipping coverage check)');
  }

  const unknownIds = printAssignments(publishedSlugs);

  console.log('\n═══ SUMMARY ═══');
  console.log(`concepts: ${CONCEPTS.length} · assignments: ${Object.keys(ASSIGNMENTS).length}`);

  const problems = validate();
  problems.forEach((p) => console.log(`  ⚠ ${p}`));
  if (unknownIds.size) console.log(`  ⚠ assignments reference unknown concept ids: ${[...unknownIds].sort().join(', ')}`);

  if (publishedSlugs) {
    const missing = [...publishedSlugs].filter((s) => !ASSIGNMENTS[s]).sort();
    const stale = Object.keys(ASSIGNMENTS).filter((s) => !publishedSlugs.has(s)).sort();
    const noTopic = Object.keys(ASSIGNMENTS).filter((s) => (ASSIGNMENTS[s].topics || []).length === 0).sort();
    const noSport = Object.keys(ASSIGNMENTS).filter((s) => !ASSIGNMENTS[s].sports).sort();
    if (missing.length) console.log(`  ⚠ published articles with NO assignment: ${missing.join(', ')}`);
    if (stale.length) console.log(`  ⚠ assignments for non-published slugs: ${stale.join(', ')}`);
    console.log(`  ℹ articles with no Topics concept (${noSport.length ? '' : ''}${noTopic.length}): ${noTopic.join(', ') || '—'}`);
    console.log(`  ℹ articles with no Sports concept (${noSport.length}): ${noSport.join(', ') || '—'}`);
  }
  if (!problems.length && !unknownIds.size) console.log('  ✓ design is internally consistent');
}

main();
