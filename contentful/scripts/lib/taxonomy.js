// Single editable source of truth for the two-scheme taxonomy (Sports + Topics) and the
// per-article assignments. `taxonomy:preview` renders everything here for review; the
// create/describe/assign scripts all read from it, so what you preview is exactly what runs.
//
// EDIT FREELY:
//   - CONCEPTS: names, hierarchy (`broader`), `altLabels`, and `description` copy.
//   - ASSIGNMENTS: each article's most-specific concept(s); the assign script EXPANDS each up
//     its `broader` chain, so an article gets the full path (e.g. a race → race+distance+discipline).
//   - altLabels start empty — add short synonyms (e.g. "70.3", "CdA") to shorten chips and
//     auto-generate /tagged/<synonym> redirects. (Leave races' altLabels off if a short form
//     would collide, e.g. the full and 70.3 Coeur d'Alene races.)
//
// Concepts/schemes are ORG-LEVEL. prefLabels for "Race Reports"/"Reviews" must stay exact
// (web share_helpers matches them). Descriptions are Markdown (rendered on the archive page,
// stripped to plain text in meta tags).

const contentful = require('contentful-management');

const LOCALE = 'en-US';
const EVENT_CONTENT_TYPE = 'event';

const SCHEMES = [
  { id: 'sports', name: 'Sports' },
  { id: 'topics', name: 'Topics' },
];

// Every concept: { id, name, scheme, broader (parent id | null), altLabels: [], description }.
const CONCEPTS = [
  // ─────────────── Sports ───────────────
  { id: 'triathlon', name: 'Triathlon', scheme: 'sports', broader: null, altLabels: [],
    description: 'Swim, bike, run---race reports, news, and training.' },

  { id: 'full-distance', name: 'Full Distance', scheme: 'sports', broader: 'triathlon', altLabels: [],
    description: 'Full-distance triathlon: a 2.4-mile swim, 112-mile bike, and 26.2-mile run.' },
  { id: 'ironman-canada', name: 'Ironman Canada', scheme: 'sports', broader: 'full-distance', altLabels: [],
    description: 'The now-defunct full-distance Ironman in Penticton, British Columbia.' },
  { id: 'ironman-coeur-dalene', name: 'Ironman Coeur d’Alene', scheme: 'sports', broader: 'full-distance', altLabels: [],
    description: 'The now-defunct full-distance Ironman in Coeur d’Alene, Idaho---140.6 miles on a challenging, unpredictable course.' },

  { id: 'half-distance', name: 'Half Distance', scheme: 'sports', broader: 'triathlon', altLabels: [],
    description: 'Half-distance triathlon: a 1.2-mile swim, 56-mile bike, and 13.1-mile run.' },
  { id: 'ironman-703-coeur-dalene', name: 'Ironman 70.3 Coeur d’Alene', scheme: 'sports', broader: 'half-distance', altLabels: [],
    description: 'The Ironman 70.3 in Coeur d’Alene, Idaho, where race day always seems to bring some weather surprise, from high winds to hailstorms to record heat.' },
  { id: 'ironman-703-boise', name: 'Ironman 70.3 Boise', scheme: 'sports', broader: 'half-distance', altLabels: [],
    description: 'The Ironman 70.3 in Boise, Idaho: a split-transition race with a Lucky Peak Reservoir swim, a bike around the Idaho countryside, and a run along the Greenbelt.' },
  { id: 'ironman-703-washington-tri-cities', name: 'Ironman 70.3 Washington Tri-Cities', scheme: 'sports', broader: 'half-distance', altLabels: [],
    description: 'A chill, late-season 70.3 in Richland, Washington, with a fast Columbia River swim, a ride past the vineyards, and a spectator-friendly run along the river.' },
  { id: 'ironman-703-st-george', name: 'Ironman 70.3 St. George', scheme: 'sports', broader: 'half-distance', altLabels: [],
    description: 'The now-defunct Ironman 70.3 in St. George, Utah, riding through Snow Canyon.' },
  { id: 'ironman-703-boulder', name: 'Ironman 70.3 Boulder', scheme: 'sports', broader: 'half-distance', altLabels: [],
    description: 'The Ironman 70.3 in Boulder, Colorado, in the shadow of the Flatirons.' },
  { id: 'ironman-703-arizona', name: 'Ironman 70.3 Arizona', scheme: 'sports', broader: 'half-distance', altLabels: [],
    description: 'The now-defunct Ironman 70.3 in Tempe, Arizona.' },
  { id: 'ironman-703-ruidoso-new-mexico', name: 'Ironman 70.3 Ruidoso', scheme: 'sports', broader: 'half-distance', altLabels: [],
    description: 'The new Ironman 70.3 in Ruidoso, New Mexico.' },

  { id: 'olympic-distance', name: 'Olympic Distance', scheme: 'sports', broader: 'triathlon', altLabels: [],
    description: 'Olympic-distance triathlon: a 1.5 km swim, 40 km bike, and 10 km run.' },
  { id: 'gates-of-yellowstone-triathlon', name: 'Gates of Yellowstone Triathlon', scheme: 'sports', broader: 'olympic-distance', altLabels: ['Gates of Yellowstone'],
    description: 'A local Olympic-distance triathlon just outside Yellowstone.' },
  { id: 'bozeman-triathlon', name: 'Bozeman Triathlon', scheme: 'sports', broader: 'olympic-distance', altLabels: [],
    description: 'An Olympic-distance triathlon in Bozeman, Montana.' },

  { id: 'triathlon-other', name: 'Other', scheme: 'sports', broader: 'triathlon', altLabels: [],
    description: 'Non-standard-distance triathlons.' },
  { id: 'escape-from-alcatraz-triathlon', name: 'Escape from Alcatraz Triathlon', scheme: 'sports', broader: 'triathlon-other', altLabels: ['Escape from Alcatraz'],
    description: 'One of the country’s oldest triathlons, with a plunge into San Francisco Bay near Alcatraz, a hilly ride through the Presidio, and a run up Baker Beach’s infamous Sand Ladder.' },

  { id: 'running', name: 'Running', scheme: 'sports', broader: null, altLabels: [],
    description: 'Running---race reports and training, from half marathons to shorter road races.' },
  { id: 'half-marathon', name: 'Half Marathon', scheme: 'sports', broader: 'running', altLabels: [],
    description: 'Half marathons---the 13.1-mile distance.' },
  { id: 'grand-teton-half-marathon', name: 'Grand Teton Half Marathon', scheme: 'sports', broader: 'half-marathon', altLabels: [],
    description: 'An early-summer half marathon along the Tetons, and one of my favorites of the year.' },
  { id: 'jackson-hole-half-marathon', name: 'Jackson Hole Half Marathon', scheme: 'sports', broader: 'half-marathon', altLabels: [],
    description: 'A fast half marathon at the foot of the Tetons, from Teton Village to downtown Jackson.' },
  { id: 'hole-half-marathon', name: 'Hole Half Marathon', scheme: 'sports', broader: 'half-marathon', altLabels: ['Hole Half'],
    description: 'A fall half marathon from Jackson to Teton Village, with the Tetons in view nearly the whole way.' },
  { id: 'running-other', name: 'Other', scheme: 'sports', broader: 'running', altLabels: [],
    description: 'Other running races---12Ks, 15Ks, and other distances.' },
  { id: 'carrera-san-silvestre-12k', name: 'Carrera San Silvestre 12K', scheme: 'sports', broader: 'running-other', altLabels: ['Carrera San Silvestre', 'San Silvestre'],
    description: 'A festive New Year’s Eve race in Mexico City.' },
  { id: 'teton-mountain-runs-wild-15k', name: 'Teton Mountain Runs Wild 15K', scheme: 'sports', broader: 'running-other', altLabels: ['Wild 15K'],
    description: 'A 15K trail running race in the Tetons.' },

  { id: 'cycling', name: 'Cycling', scheme: 'sports', broader: null, altLabels: [],
    description: 'Bikes, gear, and training on two wheels.' },
  { id: 'swimming', name: 'Swimming', scheme: 'sports', broader: null, altLabels: [],
    description: 'Pool and open-water training.' },

  // ─────────────── Topics ───────────────
  { id: 'race-reports', name: 'Race Reports', scheme: 'topics', broader: null, altLabels: [],
    description: 'Play-by-play recaps of my races: how the swim, bike, and run actually went---weather, mishaps, and all.' },
  { id: 'news', name: 'News', scheme: 'topics', broader: null, altLabels: [],
    description: 'News about triathlon and endurance sports---rule changes, race announcements, and industry updates.' },
  { id: 'reviews', name: 'Reviews', scheme: 'topics', broader: null, altLabels: [],
    description: 'Hands-on reviews of the gear I train and race with.' },
  { id: 'training', name: 'Training', scheme: 'topics', broader: null, altLabels: [],
    description: 'How I train---workouts, data, and the systems that get me to the start line ready.' },
  { id: 'nutrition-hydration', name: 'Nutrition & Hydration', scheme: 'topics', broader: 'training', altLabels: [],
    description: 'Sweat testing, sodium loss, and dialing in race-day nutrition.' },
  { id: 'tech', name: 'Tech', scheme: 'topics', broader: null, altLabels: [],
    description: 'The tech I use to train and race---gear, devices, and apps.' },
  { id: 'gear', name: 'Gear', scheme: 'topics', broader: 'tech', altLabels: [],
    description: 'The gear I swim, bike, and run with---bikes, tech, and race-day equipment.' },
  { id: 'apps', name: 'Apps', scheme: 'topics', broader: 'tech', altLabels: [],
    description: 'The apps and software I use to plan, track, and analyze my training, and the news around them.' },
  { id: 'zwift', name: 'Zwift', scheme: 'topics', broader: 'apps', altLabels: [],
    description: 'Indoor training, integrations, and updates in Watopia.' },
  { id: 'meta', name: 'Meta', scheme: 'topics', broader: null, altLabels: [],
    description: 'About this blog.' },
  { id: 'personal', name: 'Personal', scheme: 'topics', broader: null, altLabels: [],
    description: 'Personal updates---the ups and downs of chasing races, injuries and all.' },
];

// article slug → { sports: <most-specific concept id | null>, topics: [ids] }.
// Seeded from each article's current concepts, then hand-reviewed. Assign expands each up its
// broader chain. Conventions: general Ironman news → `triathlon` (the discipline, not a
// distance); tech posts keep their sport discipline; a couple of recaps carry no content-type.
const ASSIGNMENTS = {
  'a-way-to-track-my-endless-pool-workouts': { sports: 'swimming', topics: ['apps', 'training'] },
  'an-update-on-my-ankle': { sports: 'running', topics: ['personal'] },
  'best-bike-split-integrates-with-zwift': { sports: 'cycling', topics: ['zwift', 'news'] },
  'core-introduces-a-new-heat-adaptation-score': { sports: null, topics: ['gear', 'apps', 'news'] },
  'elsewhere-on-the-web': { sports: null, topics: ['meta'] },
  'escape-from-alcatraz-changes-starting-procedures-for-this-years-race': { sports: 'escape-from-alcatraz-triathlon', topics: ['news'] },
  'escaping-from-alcatraz-next-june': { sports: 'escape-from-alcatraz-triathlon', topics: ['personal'] },
  'gates-of-yellowstone-triathlon': { sports: 'gates-of-yellowstone-triathlon', topics: ['news'] },
  'ironman-70-3-is-coming-back-to-boise': { sports: 'ironman-703-boise', topics: ['news'] },
  'ironman-adopts-world-triathlon-bike-hydration-rules': { sports: 'triathlon', topics: ['news'] },
  'ironman-announces-new-performance-based-qualification': { sports: 'triathlon', topics: ['news'] },
  'ironman-comes-to-new-mexico': { sports: 'ironman-703-ruidoso-new-mexico', topics: ['news'] },
  'ironman-competition-rules-2026': { sports: 'triathlon', topics: ['news'] },
  'ironman-wont-enforce-new-world-triathlon-hydration-rules-for-age-groups': { sports: 'triathlon', topics: ['news'] },
  'new-bike-day-trek-speed-concept-slr-7': { sports: 'cycling', topics: ['gear'] },
  'new-world-triathlon-bike-hydration-rules': { sports: 'triathlon', topics: ['news'] },
  'next-years-edition-of-ironman-70-3-st-george-will-be-the-final-one': { sports: 'ironman-703-st-george', topics: ['news'] },
  'no-more-mortal-hydration-in-2026': { sports: 'triathlon', topics: ['news'] },
  'one-last-race-this-year': { sports: 'carrera-san-silvestre-12k', topics: ['personal'] },
  'paula-findlays-recap-of-ironman-70-3-boise': { sports: 'ironman-703-boise', topics: [] },
  'race-report-2024-grand-teton-half-marathon': { sports: 'grand-teton-half-marathon', topics: ['race-reports'] },
  'race-report-2024-ironman-70-3-coeur-dalene': { sports: 'ironman-703-coeur-dalene', topics: ['race-reports'] },
  'race-report-2024-ironman-70-3-st-george': { sports: 'ironman-703-st-george', topics: ['race-reports'] },
  'race-report-2024-ironman-70-3-washington-tri-cities': { sports: 'ironman-703-washington-tri-cities', topics: ['race-reports'] },
  'race-report-2024-ironman-canada': { sports: 'ironman-canada', topics: ['race-reports'] },
  'race-report-2025-grand-teton-half-marathon': { sports: 'grand-teton-half-marathon', topics: ['race-reports'] },
  'race-report-2025-hole-half-marathon': { sports: 'hole-half-marathon', topics: ['race-reports'] },
  'race-report-2025-ironman-70-3-boise': { sports: 'ironman-703-boise', topics: ['race-reports'] },
  'race-report-2025-ironman-70-3-coeur-dalene': { sports: 'ironman-703-coeur-dalene', topics: ['race-reports'] },
  'race-report-2025-ironman-70-3-st-george': { sports: 'ironman-703-st-george', topics: ['race-reports'] },
  'race-report-2025-ironman-70-3-washington-tri-cities': { sports: 'ironman-703-washington-tri-cities', topics: ['race-reports'] },
  'race-report-2025-jackson-hole-half-marathon': { sports: 'jackson-hole-half-marathon', topics: ['race-reports'] },
  'race-report-2026-escape-from-alcatraz-triathlon': { sports: 'escape-from-alcatraz-triathlon', topics: ['race-reports'] },
  'race-report-2026-ironman-70-3-coeur-dalene': { sports: 'ironman-703-coeur-dalene', topics: ['race-reports'] },
  'race-report-bozeman-triathlon': { sports: 'bozeman-triathlon', topics: ['race-reports'] },
  'race-report-carrera-san-silvestre-2024': { sports: 'carrera-san-silvestre-12k', topics: ['race-reports'] },
  'race-report-grand-teton-half-marathon': { sports: 'grand-teton-half-marathon', topics: ['race-reports'] },
  'race-report-hole-half-marathon': { sports: 'hole-half-marathon', topics: ['race-reports'] },
  'race-report-hole-half-marathon-2023': { sports: 'hole-half-marathon', topics: ['race-reports'] },
  'race-report-ironman-69-1-arizona': { sports: 'ironman-703-arizona', topics: ['race-reports'] },
  'race-report-ironman-70-3-boulder': { sports: 'ironman-703-boulder', topics: ['race-reports'] },
  'race-report-ironman-70-3-st-george': { sports: 'ironman-703-st-george', topics: ['race-reports'] },
  'race-report-ironman-coeur-dalene': { sports: 'ironman-coeur-dalene', topics: ['race-reports'] },
  'race-report-jackson-hole-half-marathon': { sports: 'jackson-hole-half-marathon', topics: ['race-reports'] },
  'race-report-wild-15k': { sports: 'teton-mountain-runs-wild-15k', topics: ['race-reports'] },
  'raceranger-age-groupers-challenge-wanaka': { sports: 'triathlon', topics: ['gear', 'news'] },
  'review-technogym-myrun': { sports: 'running', topics: ['gear', 'reviews'] },
  'runna-acquired-by-strava': { sports: 'running', topics: ['apps', 'news'] },
  'send-runna-workouts-to-zwift-using-intervals-icu': { sports: 'running', topics: ['zwift'] },
  't-2-weeks-to-escape-from-alcatraz': { sports: 'escape-from-alcatraz-triathlon', topics: [] },
  'this-years-ironman-canada-will-be-the-last-in-penticton': { sports: 'ironman-canada', topics: ['news'] },
  'trainerroad-launches-zwift-integration': { sports: 'cycling', topics: ['zwift', 'training'] },
  'welcome-to-given-to-tri': { sports: null, topics: ['meta'] },
  'well-i-had-to-skip-the-hole-half': { sports: 'hole-half-marathon', topics: ['personal'] },
  'whats-the-water-temperature-at-lucky-peak-reservoir-in-july': { sports: 'ironman-703-boise', topics: [] },
  'world-triathlon-updates-hydration-rules-again': { sports: 'triathlon', topics: ['news'] },
  'understanding-my-sweat-and-sodium-loss-rates': { sports: null, topics: ['nutrition-hydration'] },
  'zwift-automatic-incline-control-soon': { sports: 'running', topics: ['zwift', 'news'] },
};

// ─────────────── helpers ───────────────

const byId = new Map(CONCEPTS.map((c) => [c.id, c]));

// A concept's id chain, most-specific first: [id, parent, grandparent, …].
function expandAncestors(id) {
  const chain = [];
  let cur = id;
  const seen = new Set();
  while (cur && byId.has(cur) && !seen.has(cur)) {
    seen.add(cur);
    chain.push(cur);
    cur = byId.get(cur).broader;
  }
  return chain;
}

// The full set of concept ids an article should carry (both schemes' paths), de-duped in
// scheme-then-depth order (Sports discipline→distance→race, then Topics). `unknown` collects
// any id in the assignment that isn't a real concept.
function resolveAssignment(slug, unknown = []) {
  const a = ASSIGNMENTS[slug];
  if (!a) return null;
  const ids = [];
  const push = (id) => {
    if (!id) return;
    if (!byId.has(id)) { unknown.push(id); return; }
    for (const anc of expandAncestors(id).reverse()) if (!ids.includes(anc)) ids.push(anc);
  };
  push(a.sports);
  (a.topics || []).forEach(push);
  return ids;
}

const SCHEME_IDS = new Set(SCHEMES.map((s) => s.id));
function conceptsForScheme(schemeId) {
  return CONCEPTS.filter((c) => c.scheme === schemeId);
}

// Turns a title into an id in the existing style (lowercase, drop periods/apostrophes, hyphenate).
function slugify(title) {
  return title.toLowerCase().replace(/[.'’]/g, '').replace(/&/g, ' and ')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}

const conceptLink = (id) => ({ sys: { type: 'Link', linkType: 'TaxonomyConcept', id } });
const linkedIds = (links) => (links || []).map((l) => l.sys.id).sort();

async function getExistingConcepts(client, { organizationId }) {
  const items = [];
  let pageUrl;
  for (;;) {
    const page = await client.concept.getMany({ organizationId, query: pageUrl ? { pageUrl } : {} });
    items.push(...page.items);
    pageUrl = page.pages?.next;
    if (!pageUrl || page.items.length === 0) break;
  }
  return items;
}

async function getExistingSchemes(client, { organizationId }) {
  const list = await client.conceptScheme.getMany({ organizationId, query: {} });
  return list.items;
}

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

function createPlainClient() {
  const accessToken = process.env.CONTENTFUL_MANAGEMENT_TOKEN;
  if (!accessToken) {
    console.error('Missing CONTENTFUL_MANAGEMENT_TOKEN — set it in contentful/.env.');
    process.exit(1);
  }
  return contentful.createClient({ accessToken }, { type: 'plain' });
}

function readEnv({ requireOrg = false } = {}) {
  const spaceId = process.env.CONTENTFUL_SPACE;
  const organizationId = process.env.CONTENTFUL_ORGANIZATION_ID;
  const environmentId = process.env.CONTENTFUL_ENVIRONMENT || 'master';
  if (!spaceId) { console.error('Missing CONTENTFUL_SPACE — set it in contentful/.env.'); process.exit(1); }
  if (requireOrg && !organizationId) { console.error('Missing CONTENTFUL_ORGANIZATION_ID — set it in contentful/.env.'); process.exit(1); }
  return { spaceId, organizationId, environmentId, dryRun: process.env.DRY_RUN === 'true', onlyId: process.env.ENTRY_ID || null };
}

module.exports = {
  LOCALE, EVENT_CONTENT_TYPE, SCHEMES, CONCEPTS, ASSIGNMENTS, byId,
  expandAncestors, resolveAssignment, conceptsForScheme, SCHEME_IDS,
  slugify, conceptLink, linkedIds, getExistingConcepts, getExistingSchemes,
  paginateAll, createPlainClient, readEnv,
};
