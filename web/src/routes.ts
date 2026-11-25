// The paths that come to the Worker. The static asset layer serves each other path.
//
// ⚠️ `run_worker_first` in wrangler.jsonc must hold the same list, and no code can import that
// file. test/browser/worker_routes.test.js compares the two.
// ⚠️ A new entry also needs an exclusion in the Cache Rule of the zone. Refer to the root
// CLAUDE.md.

/** The widget fragments of the api. The path after the prefix goes to the origin with no change. */
export const WIDGETS_PREFIX = '/widgets/';

/**
 * The contact-form endpoint. It is this one path and not `/api/*`, thus a browser cannot reach
 * the other /api endpoints, which are on the origin only.
 */
export const CONTACT_PATH = '/api/contact';

// The first-party proxy of Plausible. The two paths must agree with PLAUSIBLE_SCRIPT_PATH and
// PLAUSIBLE_EVENT_PATH in web/lib/helpers/site_helpers.rb, which make the inline init code.
export const PLAUSIBLE_PREFIX = '/pa/';
export const PLAUSIBLE_SCRIPT_PATH = `${PLAUSIBLE_PREFIX}script.js`;
export const PLAUSIBLE_EVENT_PATH = `${PLAUSIBLE_PREFIX}event`;

// The file name of an Open Graph card. Keep the ".png": wrangler.jsonc gives the reason.
export const OG_FILENAME = 'og.png';

/** True for each path of the card route: `/og.png` and `/<page path>og.png`. */
export const isOgPath = (pathname: string): boolean =>
  pathname.endsWith(`/${OG_FILENAME}`);

/** The `run_worker_first` globs that the constants above make. */
export const WORKER_FIRST_GLOBS = [
  `${WIDGETS_PREFIX}*`,
  CONTACT_PATH,
  `${PLAUSIBLE_PREFIX}*`,
  `/${OG_FILENAME}`,
  `/*/${OG_FILENAME}`,
];
