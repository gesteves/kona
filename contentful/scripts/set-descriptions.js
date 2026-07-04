// Sets each taxonomy concept's `definition` (the description shown on its /tagged archive
// page and in that page's meta/OG description). Idempotent, skip-unchanged, DRY_RUN — patches
// ONLY the definition, so it never disturbs prefLabel/broader (and create-taxonomy.js never
// touches definition, so the two don't fight).
//
// The DESCRIPTIONS below are a first draft grounded in the site's content — tweak the copy
// freely (Markdown is supported; it renders on the archive page and is stripped to plain text
// for the meta tags), then run. Concepts with no entry here are left as-is; ids with no
// matching concept are reported and skipped.
//
// Env: CONTENTFUL_MANAGEMENT_TOKEN, CONTENTFUL_ORGANIZATION_ID (concepts are org-level).
//   DRY_RUN=true prints the plan and writes nothing.
// Run: `npm run taxonomy:describe`.

const { LOCALE, getExistingConcepts, createPlainClient, readEnv } = require('./lib/taxonomy');

const DESCRIPTIONS = {
  // — Topics —
  triathlon: 'Swim, bike, run. Race reports, news, and other articles about triathlons.',
  ironman: 'News, articles, and race reports about full-distance Ironman racing.',
  'ironman-703': 'News, articles, and race reports about half-distance Ironman racing.',
  olympic: 'News, articles, and race reports about Olympic-distance triathlons.',
  running: 'Race reports for running races and articles about running training.',
  'half-marathon': 'Race reports about half-marathons and articles about training for them.',
  cycling: 'Bikes, gear, and the tools I use to train and race on two wheels.',
  swimming: 'Gear and tools I use to train in the water.',
  'race-reports': 'Play-by-play recaps of my races: how the swim, bike, and run actually went---weather, mishaps, and all.',
  news: 'News about triathlon and endurance sports---rule changes, race announcements, and industry updates.',
  reviews: 'Hands-on reviews of the gear I train and race with.',
  training: 'How I train---workouts, data, apps, and tools that get me to the start line ready.',
  'nutrition-hydration': 'Articles about sweat testing, sodium loss, and dialing in race-day nutrition.',
  gear: 'The gear I swim, bike, and run with---bikes, tech, and race-day equipment.',
  apps: 'The apps and software I use to plan, track, and analyze my training, and the news around them.',
  zwift: 'Indoor training, integrations, and updates to the virtual world I ride and run in.',
  meta: 'About this blog.',
  personal: 'Personal updates---the ups and downs of chasing races, injuries and all.',

  // — Races —
  races: 'Every race I’ve toed the line for, or I’m planning to.',
  'ironman-703-coeur-dalene': 'The Ironman 70.3 in Coeur d’Alene, Idaho, where race day always seems to bring some weather surprise, from high winds to hailstorms to record heat.',
  'escape-from-alcatraz-triathlon': 'One of the country’s oldest triathlons, with a plunge into San Francisco Bay near Alcatraz, a hilly ride through the Presidio, and a run up Baker Beach’s infamous Sand Ladder.',
  'ironman-703-boise': 'The Ironman 70.3 in Boise, Idaho: a split-transition race with a Lucky Peak Reservoir swim, a bike around the Idaho countryside, and a run along the Greenbelt.',
  'ironman-703-washington-tri-cities': 'A chill, late-season 70.3 in Richland, Washington, with a fast Columbia River swim, a ride past the vineyards, and a spectator-friendly run along the river.',
  'gates-of-yellowstone-triathlon': 'A local Olympic-distance triathlon just outside Yellowstone.',
  'hole-half-marathon': 'A fall half marathon from Jackson to Teton Village, with the Tetons in view nearly the whole way.',
  'carrera-san-silvestre-12k': 'A festive New Year’s Eve 12K in Mexico City.',
  'grand-teton-half-marathon': 'An early-summer half marathon along the Tetons, and one of my favorites of the year.',
  'jackson-hole-half-marathon': 'A fast half marathon at the foot of the Tetons, from Teton Village to downtown Jackson.',
  'ironman-canada': 'The now-defunct full-distance Ironman in Penticton, British Columbia.',
  'ironman-703-boulder': 'The Ironman 70.3 in Boulder, Colorado, in the shadow of the Flatirons.',
  'ironman-703-st-george': 'The now-defunct Ironman 70.3 in St. George, Utah, riding through Snow Canyon.',
  'teton-mountain-runs-wild-15k': 'A 15K trail race in the Tetons.',
  'ironman-coeur-dalene': 'The now-defunct full-distance Ironman in Coeur d’Alene, Idaho---140.6 miles on a challenging, unpredictable course.',
  'ironman-703-arizona': 'The now-defunct Ironman 70.3 in Tempe, Arizona.',
  'bozeman-triathlon': 'An Olympic-distance triathlon in Bozeman, Montana.',
};

async function run() {
  const { organizationId, dryRun } = readEnv({ requireOrg: true });
  const client = createPlainClient();

  const existing = await getExistingConcepts(client, { organizationId });
  const byId = new Map(existing.map((c) => [c.sys.id, c]));

  let updated = 0;
  let unchanged = 0;
  const missing = [];

  for (const [id, text] of Object.entries(DESCRIPTIONS)) {
    const concept = byId.get(id);
    if (!concept) {
      missing.push(id);
      continue;
    }
    if (concept.definition?.[LOCALE] === text) {
      unchanged += 1;
      continue;
    }
    console.log(`~ ${id}: ${text}`);
    updated += 1;
    if (!dryRun) {
      await client.concept.patch(
        { organizationId, conceptId: id, version: concept.sys.version },
        [{ op: 'add', path: '/definition', value: { [LOCALE]: text } }]
      );
    }
  }

  console.log(`\n${dryRun ? '[DRY RUN] ' : ''}descriptions — updated: ${updated}, unchanged: ${unchanged}`);
  if (missing.length) {
    console.warn(`⚠ ${missing.length} description id(s) have no matching concept (skipped): ${missing.sort().join(', ')}`);
  }
}

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
