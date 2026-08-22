// The one source of the two-scheme taxonomy and of the concepts of each article. You can edit it.
// `taxonomy:preview` shows all the content here for a review, and the create, describe, and assign
// scripts read it. Thus the preview shows exactly what the scripts do.
//
// You can edit these: the names, the tree, the altLabels, and the descriptions in CONCEPTS, and the
// most specific concepts of each article in ASSIGNMENTS. The assign script adds each parent from
// the `broader` chain, thus an article gets the full path. An altLabel makes a chip shorter and
// makes a /tagged/<synonym> redirect. Thus do not give an altLabel where a short form would be the
// same as another one.
//
// ⚠️ The concepts and the schemes belong to the organization. The prefLabels "Race Reports" and
// "Reviews" must stay exactly the same, because the share_helpers of web match them. Each
// description is Markdown.

const contentful = require('contentful-management');

const LOCALE = 'en-US';
const EVENT_CONTENT_TYPE = 'event';

const SCHEMES = [
  { id: 'sports', name: 'Sports' },
  { id: 'topics', name: 'Topics' },
];

// Each concept: { id, name, scheme, broader (the parent id or null), altLabels: [], description }.
const CONCEPTS = [
  // ─────────────── Sports ───────────────
  { id: 'triathlon', name: 'Triathlon', scheme: 'sports', broader: null, altLabels: [],
    description: 'Swim, bike, run---race reports, news, and training.' },

  { id: 'full-distance', name: 'Full Distance', scheme: 'sports', broader: 'triathlon', altLabels: [],
    description: 'Full-distance triathlon: a 2.4-mile swim, 112-mile bike, and 26.2-mile run.' },
  { id: 'ironman-canada', name: 'Ironman Canada', scheme: 'sports', broader: 'full-distance', altLabels: [],
    description: 'The now-defunct full-distance Ironman in Penticton, British Columbia---140.6 miles in the heart of the Okanagan Valley, with a swim in Okanagan Lake, a bike through the surrounding wine country and orchards, and a run along the water and streets downtown. A storied race with deep roots in Penticton; 2024 was its final edition there before Ironman relocated the race to Ottawa.' },
  { id: 'ironman-coeur-dalene', name: 'Ironman Coeur d’Alene', scheme: 'sports', broader: 'full-distance', altLabels: [],
    description: 'The now-defunct full-distance Ironman in Coeur d’Alene, Idaho---140.6 miles based out of the downtown lakefront, built around a lovely swim in Lake Coeur d’Alene, a challenging and hilly bike, and one of the best run courses in the North American circuit.' },

  { id: 'half-distance', name: 'Half Distance', scheme: 'sports', broader: 'triathlon', altLabels: [],
    description: 'Half-distance triathlon: a 1.2-mile swim, 56-mile bike, and 13.1-mile run.' },
  { id: 'ironman-703-coeur-dalene', name: 'Ironman 70.3 Coeur d’Alene', scheme: 'sports', broader: 'half-distance', altLabels: [],
    description: 'The Ironman 70.3 in Coeur d’Alene, Idaho---a scenic lake swim, a challenging bike up into the surrounding countryside, and one of the best run courses in the North American circuit. A spectator-friendly race with a well-earned reputation for dramatic race-day weather---anything from high winds and surprise hailstorms to record heat can and has happened here.' },
  { id: 'ironman-703-boise', name: 'Ironman 70.3 Boise', scheme: 'sports', broader: 'half-distance', altLabels: [],
    description: 'The Ironman 70.3 in Boise, Idaho, a split-transition race: It starts with a swim in the snowmelt-fed Lucky Peak Reservoir, heads out on a bike through the Idaho countryside, and finishes with a run along the Boise River Greenbelt, a gorgeous tree-lined path and one of the nicest places anywhere to end a race. Originally run from 2008 to 2015, it returned in 2025 with a late-July date that can bring real heat.' },
  { id: 'ironman-703-washington-tri-cities', name: 'Ironman 70.3 Washington Tri-Cities', scheme: 'sports', broader: 'half-distance', altLabels: [],
    description: 'A chill, late-season 70.3 in Richland, Washington. It features a fast, downriver swim in the Columbia River, a scenic bike past vineyards and farm roads, and a flat, spectator-friendly run along the riverfront, with several hotels within walking distance of transition and the finish. A relaxed, well-run event and a great way to close out a season.' },
  { id: 'ironman-703-st-george', name: 'Ironman 70.3 St. George', scheme: 'sports', broader: 'half-distance', altLabels: [],
    description: 'The now-defunct Ironman 70.3 in St. George, Utah---a genuinely tough, scenic 70.3 in red-rock country. A reservoir swim at Sand Hollow State Park led into a demanding bike that climbs through gorgeous Snow Canyon State Park, and a run through town, with a split transition between the two. Often hot and always beautiful; 2025 was its final edition for the foreseeable future.' },
  { id: 'ironman-703-boulder', name: 'Ironman 70.3 Boulder', scheme: 'sports', broader: 'half-distance', altLabels: [],
    description: 'The Ironman 70.3 in Boulder, Colorado, raced in the shadow of the Flatirons. A reservoir swim at the Boulder Reservoir, a bike out onto the rolling roads north of town, and a run to the finish---a fast course on paper that can turn brutal when the Colorado sun and summer heat show up.' },
  { id: 'ironman-703-arizona', name: 'Ironman 70.3 Arizona', scheme: 'sports', broader: 'half-distance', altLabels: [],
    description: 'The now-defunct Ironman 70.3 in Tempe, Arizona, based out of Tempe Beach Park, with a swim in Tempe Town Lake, a three-lap bike around the city, and a flat, fast run around the lake.' },
  { id: 'ironman-703-ruidoso-new-mexico', name: 'Ironman 70.3 Ruidoso', scheme: 'sports', broader: 'half-distance', altLabels: [],
    description: 'Ironman’s new-for-2026 70.3 in Ruidoso, New Mexico---a high-altitude race in a scenic mountain town at around <span data-imperial="6,700 feet">2,000 meters</span> of elevation, run as part of a festival weekend that also includes Olympic- and sprint-distance races.' },

  { id: 'olympic-distance', name: 'Olympic Distance', scheme: 'sports', broader: 'triathlon', altLabels: [],
    description: 'Olympic-distance triathlon: a 1.5 km swim, 40 km bike, and 10 km run.' },
  { id: 'gates-of-yellowstone-triathlon', name: 'Gates of Yellowstone Triathlon', scheme: 'sports', broader: 'olympic-distance', altLabels: ['Gates of Yellowstone'],
    description: 'A small, locally organized triathlon in Cody, Wyoming, just outside the gates of Yellowstone National Park. It offers sprint and Olympic distances plus an Olympic relay---a low-key, community race in a beautiful corner of northwest Wyoming.' },
  { id: 'bozeman-triathlon', name: 'Bozeman Triathlon', scheme: 'sports', broader: 'olympic-distance', altLabels: [],
    description: 'An Olympic-distance triathlon in Bozeman, Montana, held at Glen Lake Rotary Park---a former gravel pit turned swimming hole. A two-lap lake swim with an Aussie exit in between, a bike out into the countryside, and a run to finish. An approachable, well-organized local race, and a great Olympic-distance triathlon.' },

  { id: 'triathlon-other', name: 'Other', scheme: 'sports', broader: 'triathlon', altLabels: [],
    description: 'Non-standard-distance triathlons.' },
  { id: 'escape-from-alcatraz-triathlon', name: 'Escape from Alcatraz Triathlon', scheme: 'sports', broader: 'triathlon-other', altLabels: ['Escape from Alcatraz'],
    description: 'One of the oldest and most iconic triathlons in the country, and a true bucket-list race. Athletes leap off the deck of the <i>San Francisco Belle</i> near Alcatraz Island for a <span data-imperial="1.5-mile">2.4 km</span> swim through the cold waters of San Francisco Bay, ride <span data-imperial="an 18-mile">a 29 km</span> hilly bike through the Presidio of San Francisco and Golden Gate Park, and finish with <span data-imperial="an 8-mile">a 12.9 km</span> trail run that climbs the four hundred steps of Baker Beach’s infamous Sand Ladder.' },

  { id: 'running', name: 'Running', scheme: 'sports', broader: null, altLabels: [],
    description: 'Running---race reports and training, from half marathons to shorter road races.' },
  { id: 'half-marathon', name: 'Half Marathon', scheme: 'sports', broader: 'running', altLabels: [],
    description: 'Half marathons---the 13.1-mile distance.' },
  { id: 'grand-teton-half-marathon', name: 'Grand Teton Half Marathon', scheme: 'sports', broader: 'half-marathon', altLabels: [],
    description: 'An early-summer half marathon in Jackson Hole, and the biggest and best-organized of the valley’s three local halves, with around two thousand runners. The course runs from the Stilson Lot out toward Wilson and back, crossing the Snake River before turning up Spring Gulch Road, with the Teton Range in view all the way to the finish at the Jackson Hole Golf Club. Mostly flat and fast, run at altitude (about <span data-imperial="6,250 feet">1,905 m</span>), with great swag and gorgeous scenery.' },
  { id: 'jackson-hole-half-marathon', name: 'Jackson Hole Half Marathon', scheme: 'sports', broader: 'half-marathon', altLabels: [],
    description: 'The smallest of Jackson Hole’s three local half marathons, often under two hundred runners, and a deceptively competitive one at altitude. The course runs from Teton Village south toward Wilson and on into town, crossing the Snake River and winding along the community pathways to finish at Phil Baux Park, at the foot of Snow King. Mostly downhill and scenic---a fast late-spring race.' },
  { id: 'hole-half-marathon', name: 'Hole Half Marathon', scheme: 'sports', broader: 'half-marathon', altLabels: ['Hole Half'],
    description: 'A chill fall half marathon in Jackson Hole, run alongside the Jackson Hole Marathon and roughly the reverse of the [Jackson Hole Half](/tagged/running/half-marathon/jackson-hole-half-marathon/). It starts in downtown Jackson and heads north along the community pathway to finish at the Jackson Hole Mountain Resort in Teton Village, with the Tetons in view nearly the whole way. A mild uphill grade over the final stretch, crisp fall weather, and peak foliage make it a beautiful way to close out the running season.' },
  { id: 'running-other', name: 'Other', scheme: 'sports', broader: 'running', altLabels: [],
    description: 'Other running races---12Ks, 15Ks, and other distances.' },
  { id: 'carrera-san-silvestre-12k', name: 'Carrera San Silvestre 12K', scheme: 'sports', broader: 'running-other', altLabels: ['Carrera San Silvestre', 'San Silvestre'],
    description: 'A festive 12K through Mexico City on New Year’s Eve---a San Silvestre, the Latin American tradition of running out the old year that traces back to a 1925 race in São Paulo. Run near Paseo de la Reforma and Chapultepec, it’s a lively street race and a quintessentially Mexico City way to end the year.' },
  { id: 'teton-mountain-runs-wild-15k', name: 'Teton Mountain Runs Wild 15K', scheme: 'sports', broader: 'running-other', altLabels: ['Wild 15K'],
    description: 'A 15K trail race on the hiking and mountain-biking trails of Jackson Hole Mountain Resort in Teton Village. It’s the beginner-friendly option in the Teton Mountain Runs series (alongside 30K and 50K distances), with around <span data-imperial="1,800 feet">550 meters</span> of climbing and no technical scrambling---a scenic, approachable introduction to mountain trail racing.' },

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

// The article slug → { sports: the most specific concept id, or null, topics: [ids] }.
// This starts from the current concepts of each article, and then a person reads it. The assign
// script adds each parent from the broader chain. The rules: general Ironman news goes to
// `triathlon`, which is the discipline and not a distance; a tech post keeps its sport discipline;
// and two recaps have no content type.
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

// The chain of ids of a concept, the most specific first: [id, parent, parent of the parent, …].
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

// The full set of concept ids that an article must have, that is, the paths of the two schemes.
// The code removes each copy and puts them in order by scheme and then by depth: Sports gives the
// discipline, the distance, and the race, and then Topics follows. `unknown` collects each id in
// the assignment that is not a true concept.
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

// Changes a title into an id in the same style as the others: lowercase, with no period and no
// apostrophe, and with a hyphen between the words.
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
