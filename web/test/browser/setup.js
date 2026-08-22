import { afterEach, beforeEach, vi } from 'vitest';
import { restoreStubbedProperties, stopMountedApplications } from './helpers';

// The setup for the jsdom project, which the tests call "browser". It does two things: it adds the
// APIs that jsdom does not have and that this code calls, and it makes sure that each test starts
// with a clean document, a clean `window`, and no Stimulus application.
//
// The replacements below are simple defaults, and not true simulations, on purpose. A test that
// needs one of them replaces it (`window.matchMedia = () => ({ matches: true })`), and afterEach
// puts the default back. Thus a test that does not need one never fails because a global is
// absent.

// jsdom has no matchMedia. The default: no media query matches, that is, the plain condition with
// no reduced motion and the light mode.
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

// jsdom has neither requestIdleCallback nor Element#scrollTo. It defines the second one, but that
// one raises "Not implemented". The code calls both only for their results on the page, thus a
// stub that runs immediately and a stub that does nothing are correct. `preloadPagefindWhenIdle`
// tests if requestIdleCallback is absent, thus its own suite removes this stub to run the code for
// Safari 16.
const defaultRequestIdleCallback = (callback) => {
  callback({ didTimeout: false, timeRemaining: () => 50 });
  return 0;
};

beforeEach(() => {
  window.matchMedia = defaultMatchMedia;
  window.requestIdleCallback = defaultRequestIdleCallback;
  window.cancelIdleCallback = () => {};
  document.documentElement.scrollTo = () => {};
  // jsdom defines window.scrollTo but raises "Not implemented". nav_controller calls it to put the
  // reader back at their position when the menu closes.
  window.scrollTo = () => {};
});

afterEach(() => {
  // The order is important: disconnect the controllers before you remove the DOM that they use.
  // Thus a disconnect() that changes its element, for example to stop a timer or a fetch, finds a
  // live tree.
  stopMountedApplications();
  restoreStubbedProperties();

  document.body.innerHTML = '';
  document.head.innerHTML = '';
  document.body.className = '';

  // Each value that the code under test puts on `window` and keeps. Without this, the second test
  // of the contact suite would use the Turnstile promise from the first test.
  delete window.turnstile;
  delete window.__konaTurnstileLoad;
  delete window.__konaTurnstileOnload;
  delete window.plausible;
  delete window.PagefindComponents;

  vi.unstubAllGlobals();
  vi.restoreAllMocks();
  vi.useRealTimers();

  // The suites that navigate — share, units, and analytics — add query strings. Set the location
  // back, thus the `new URL(window.location.href)` of the next test starts from a known path.
  window.history.replaceState({}, '', '/');
});
