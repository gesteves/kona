import { afterEach, beforeEach, vi } from 'vitest';
import { restoreStubbedProperties, stopMountedApplications } from './helpers';

// Setup for the jsdom ("browser") project. Two jobs: fill the APIs jsdom omits that this code
// calls, and guarantee every test starts from a clean document, a clean `window`, and no live
// Stimulus application.
//
// The polyfills below are deliberately dumb defaults, not simulations. A test that cares about
// one of them overrides it (`window.matchMedia = () => ({ matches: true })`), and afterEach puts
// the default back. The point is that an *un*interested test never crashes on a missing global.

// jsdom has no matchMedia at all. Default: no media query matches, i.e. the plain
// non-reduced-motion, light-mode case.
const defaultMatchMedia = (query) => ({
  matches: false,
  media: query,
  onchange: null,
  addEventListener: () => {},
  removeEventListener: () => {},
  addListener: () => {},
  removeListener: () => {},
  dispatchEvent: () => false,
});

// jsdom implements neither requestIdleCallback nor Element#scrollTo (the latter is defined but
// throws "Not implemented"). Both are called for side effects only, so a synchronous stand-in and
// a no-op are honest stubs. `preloadPagefindWhenIdle` explicitly branches on requestIdleCallback
// being absent, so its own suite deletes this to exercise the Safari-16 fallback path.
const defaultRequestIdleCallback = (callback) => {
  callback({ didTimeout: false, timeRemaining: () => 50 });
  return 0;
};

beforeEach(() => {
  window.matchMedia = defaultMatchMedia;
  window.requestIdleCallback = defaultRequestIdleCallback;
  window.cancelIdleCallback = () => {};
  document.documentElement.scrollTo = () => {};
  // jsdom defines window.scrollTo but throws "Not implemented"; nav_controller calls it to
  // restore the reader's position when the menu closes.
  window.scrollTo = () => {};
});

afterEach(() => {
  // Order matters: disconnect controllers before wiping the DOM they're bound to, so a
  // disconnect() that touches its element (clearing timers, aborting fetches) sees a live tree.
  stopMountedApplications();
  restoreStubbedProperties();

  document.body.innerHTML = '';
  document.head.innerHTML = '';
  document.body.className = '';

  // Anything the code under test parks on `window` and memoizes. Left in place, the contact
  // suite's second test would reuse the first test's resolved Turnstile promise.
  delete window.turnstile;
  delete window.__konaTurnstileLoad;
  delete window.__konaTurnstileOnload;
  delete window.plausible;
  delete window.PagefindComponents;

  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  vi.useRealTimers();

  // The suites that navigate (share, units, analytics) push query strings; reset so the next
  // test's `new URL(window.location.href)` starts from a known path.
  window.history.replaceState({}, '', '/');
});
