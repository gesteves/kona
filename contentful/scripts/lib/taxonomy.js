// Shared data + helpers for the Contentful tags → taxonomy migration.
//
// Everything the taxonomy scripts need in one place: the canonical Topics hierarchy
// (the 18 existing metadata tags, re-created as SKOS concepts with identical ids and
// names), a new Races branch (one concept per race), the slug function, the races that
// exist only in old race reports (no `event` entry), the article-slug → race-concept map
// for race reports with no `event` link, and a plain contentful-management client factory.
//
// ⚠️ Concept ids and prefLabels are load-bearing:
//   - ids become the `/tagged/<id>` URL segments in web/ (renaming an id moves a URL).
//   - prefLabels are the display names the feed (<category>), Open Graph (article:tag),
//     JSON-LD (keywords / articleSection), and share_helpers.rb name-matching all read.
// Keep the topic prefLabels below EQUAL to the old tag names, or those surfaces drift.
//
// Concepts/schemes are ORG-LEVEL, so the CMA client here is authenticated with a
// management token and addressed by CONTENTFUL_ORGANIZATION_ID — not the space/environment
// the entry scripts use.

const contentful = require('contentful-management');

// Contentful is single-locale here; all localized concept fields use this key.
const LOCALE = 'en-US';

// The content type id whose entries are races (used to derive race concepts).
const EVENT_CONTENT_TYPE = 'event';

// The single concept scheme all concepts belong to.
const SCHEME = { id: 'topics', name: 'Topics' };

// The 18 existing tags → concepts. `id`/`name` are copied verbatim from the current tag
// vocabulary (web/data/tags.json); `broader` is the parent concept id (null = topConcept).
// Order here is the intended topConcept order in the scheme.
const TOPICS = [
  { id: 'triathlon', name: 'Triathlon', broader: null },
  { id: 'ironman', name: 'Ironman', broader: 'triathlon' },
  { id: 'ironman-703', name: 'Ironman 70.3', broader: 'triathlon' },
  { id: 'olympic', name: 'Olympic', broader: 'triathlon' },
  { id: 'running', name: 'Running', broader: null },
  { id: 'half-marathon', name: 'Half Marathon', broader: 'running' },
  { id: 'cycling', name: 'Cycling', broader: null },
  { id: 'swimming', name: 'Swimming', broader: null },
  { id: 'race-reports', name: 'Race Reports', broader: null },
  { id: 'news', name: 'News', broader: null },
  { id: 'reviews', name: 'Reviews', broader: null },
  { id: 'training', name: 'Training', broader: null },
  { id: 'nutrition-hydration', name: 'Nutrition & Hydration', broader: 'training' },
  { id: 'gear', name: 'Gear', broader: null },
  { id: 'apps', name: 'Apps', broader: null },
  { id: 'zwift', name: 'Zwift', broader: 'apps' },
  { id: 'meta', name: 'Meta', broader: null },
  { id: 'personal', name: 'Personal', broader: null },
  // Races: a new topConcept whose children are individual races (added in getRaceConcepts).
  { id: 'races', name: 'Races', broader: null },
];

// Races that exist only in old race reports with no `event` entry to derive them from.
// (The other race concepts are derived from live `event` entries at runtime — see
// getRaceConcepts — so they aren't hardcoded here.) `broader` is always `races`.
const STATIC_EXTRA_RACES = [
  { id: 'teton-mountain-runs-wild-15k', name: 'Teton Mountain Runs Wild 15K', broader: 'races' },
  { id: 'ironman-coeur-dalene', name: 'Ironman Coeur d’Alene', broader: 'races' },
  { id: 'ironman-703-arizona', name: 'Ironman 70.3 Arizona', broader: 'races' },
  { id: 'bozeman-triathlon', name: 'Bozeman Triathlon', broader: 'races' },
];

// Race reports whose `event` reference field is empty, so their race concept can't be
// derived from the linked event. Maps the article slug → the race concept id it should get.
// Three point at races that DO have `event` entries (the article just isn't linked to them);
// four point at STATIC_EXTRA_RACES above.
const ARTICLE_RACE_MAP = {
  'race-report-carrera-san-silvestre-2024': 'carrera-san-silvestre-12k',
  'race-report-2024-ironman-canada': 'ironman-canada',
  'race-report-ironman-70-3-boulder': 'ironman-703-boulder',
  'race-report-wild-15k': 'teton-mountain-runs-wild-15k',
  'race-report-ironman-coeur-dalene': 'ironman-coeur-dalene',
  'race-report-ironman-69-1-arizona': 'ironman-703-arizona',
  'race-report-bozeman-triathlon': 'bozeman-triathlon',
};

// Turns a race title into a concept id in the same style as the existing tag ids:
// lowercase, drop periods and apostrophes (straight or curly), collapse the rest to hyphens.
//   "Ironman 70.3 Coeur d’Alene" → "ironman-703-coeur-dalene"
//   "Ironman 70.3 St. George"    → "ironman-703-st-george"
//   "Carrera San Silvestre 12K"  → "carrera-san-silvestre-12k"
function slugify(title) {
  return title
    .toLowerCase()
    .replace(/[.'’]/g, '')
    .replace(/&/g, ' and ')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

// Derives the race concepts from the live `event` entries plus the static extras.
// Returns [{ id, name, broader: 'races' }], de-duplicated by id (static extras win on
// collision, though there shouldn't be any). Pass the plain CMA client + space/environment.
async function getRaceConcepts(client, { spaceId, environmentId }) {
  const events = await paginateAll((skip) =>
    client.entry.getMany({
      spaceId,
      environmentId,
      query: { content_type: EVENT_CONTENT_TYPE, skip, limit: 100, order: 'sys.createdAt' },
    })
  );

  const byId = new Map();
  for (const event of events) {
    const title = event.fields?.title?.['en-US'];
    if (!title) continue;
    const id = slugify(title);
    byId.set(id, { id, name: title, broader: 'races' });
  }
  for (const race of STATIC_EXTRA_RACES) byId.set(race.id, race);
  return [...byId.values()];
}

// The full concept list (topics + derived races) the create/delete scripts reconcile.
async function getAllConcepts(client, opts) {
  const races = await getRaceConcepts(client, opts);
  return [...TOPICS, ...races];
}

// Pages through a getMany endpoint (limit/skip/total) and returns every item.
async function paginateAll(fetchPage) {
  const items = [];
  let skip = 0;
  for (;;) {
    const page = await fetchPage(skip);
    items.push(...page.items);
    skip += page.items.length;
    if (skip >= page.total || page.items.length === 0) break;
  }
  return items;
}

// Fetches every existing concept in the org. Concepts use CURSOR pagination
// (`pages.next` is a full pageUrl passed back as `query.pageUrl`), not skip/limit.
async function getExistingConcepts(client, { organizationId }) {
  const items = [];
  let pageUrl;
  for (;;) {
    const page = await client.concept.getMany({
      organizationId,
      query: pageUrl ? { pageUrl } : {},
    });
    items.push(...page.items);
    pageUrl = page.pages?.next;
    if (!pageUrl || page.items.length === 0) break;
  }
  return items;
}

// A TaxonomyConcept link, as stored in a concept's `broader`/`related`, a scheme's
// `topConcepts`/`concepts`, and an entry's `metadata.concepts`.
function conceptLink(id) {
  return { sys: { type: 'Link', linkType: 'TaxonomyConcept', id } };
}

// The concept ids linked in a `broader` (or any TaxonomyConcept link array), sorted.
function linkedIds(links) {
  return (links || []).map((l) => l.sys.id).sort();
}

// Builds a plain contentful-management client (built-in 429 retry). Requires a CMA token.
function createPlainClient() {
  const accessToken = process.env.CONTENTFUL_MANAGEMENT_TOKEN;
  if (!accessToken) {
    console.error('Missing CONTENTFUL_MANAGEMENT_TOKEN — set it in contentful/.env.');
    process.exit(1);
  }
  return contentful.createClient({ accessToken }, { type: 'plain' });
}

// Reads the env vars the scripts share, exiting with a clear message if a required one
// is missing. `org` is required only for the org-level taxonomy CRUD scripts.
function readEnv({ requireOrg = false } = {}) {
  const spaceId = process.env.CONTENTFUL_SPACE;
  const organizationId = process.env.CONTENTFUL_ORGANIZATION_ID;
  const environmentId = process.env.CONTENTFUL_ENVIRONMENT || 'master';
  if (!spaceId) {
    console.error('Missing CONTENTFUL_SPACE — set it in contentful/.env.');
    process.exit(1);
  }
  if (requireOrg && !organizationId) {
    console.error('Missing CONTENTFUL_ORGANIZATION_ID — set it in contentful/.env.');
    process.exit(1);
  }
  return {
    spaceId,
    organizationId,
    environmentId,
    dryRun: process.env.DRY_RUN === 'true',
    onlyId: process.env.ENTRY_ID || null,
  };
}

module.exports = {
  LOCALE,
  EVENT_CONTENT_TYPE,
  SCHEME,
  TOPICS,
  STATIC_EXTRA_RACES,
  ARTICLE_RACE_MAP,
  slugify,
  getRaceConcepts,
  getAllConcepts,
  getExistingConcepts,
  conceptLink,
  linkedIds,
  paginateAll,
  createPlainClient,
  readEnv,
};
