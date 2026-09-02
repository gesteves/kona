import { beforeEach, describe, expect, it, vi } from 'vitest';

// The on-demand loader for the Pagefind Component UI. Two behaviors here are necessary, and a
// change can break them with no message:
//
//   1. the code puts the stylesheet BEFORE the first stylesheet in the page, and never at the end.
//      The dark-mode --pf-* values in _pagefind.scss win by the source order alone. Thus at the end
//      the search modal renders light at night, for all time.
//   2. a module load that fails must still RESOLVE. `customElements.whenDefined` for a script that
//      gave a 404 never resolves, and that would stop `search#open` in development.

const CSS_HREF = '/pagefind/pagefind-component-ui.css';
const JS_SRC = '/pagefind/pagefind-component-ui.js';

let pagefind;

const injectedCss = () =>
  document.head.querySelector(`link[href="${CSS_HREF}"]`);
const injectedJs = () => document.head.querySelector(`script[src="${JS_SRC}"]`);
// The custom element registry belongs to the jsdom instance, and each test in this file shares that
// instance. The module registry is different: vi.resetModules() cannot empty this one, and a second
// define() with the same name raises. Thus the code defines the element one time and each later
// test uses it.
const definePagefindModal = () => {
  if (!customElements.get('pagefind-modal')) {
    customElements.define('pagefind-modal', class extends HTMLElement {});
  }
};

const stylesheets = () =>
  [...document.head.querySelectorAll('link[rel="stylesheet"]')].map((link) =>
    link.getAttribute('href')
  );

beforeEach(async () => {
  // `loading` and `idleScheduled` are module state, and they are the values that these tests check.
  // Import the module again for each test, thus each test starts with nothing loaded.
  vi.resetModules();
  pagefind = await import('../../../source/javascripts/stimulus/lib/pagefind');
});

describe('loadPagefind', () => {
  it('injects the stylesheet and the component module', () => {
    pagefind.loadPagefind();

    expect(injectedCss()).not.toBeNull();
    expect(injectedJs().type).toBe('module');
  });

  it('inserts its stylesheet BEFORE any existing one', () => {
    document.head.innerHTML =
      '<link rel="stylesheet" href="/stylesheets/site.css">';

    pagefind.loadPagefind();

    // The source order is the only reason that the dark-mode rules win. With the stylesheet at the
    // end, the modal is light in the dark mode, and only this order in the DOM shows the cause.
    expect(stylesheets()).toEqual([CSS_HREF, '/stylesheets/site.css']);
  });

  it('appends cleanly when there is no existing stylesheet', () => {
    expect(() => pagefind.loadPagefind()).not.toThrow();
    expect(injectedCss()).not.toBeNull();
  });

  it('marks neither element with data-turbo-track, so both survive navigation', () => {
    // Turbo removes each stylesheet with the `dynamic` mark that is not in the new <head>. No
    // rendered page contains these, thus the mark would remove them at the first navigation.
    pagefind.loadPagefind();

    expect(injectedCss().hasAttribute('data-turbo-track')).toBe(false);
    expect(injectedJs().hasAttribute('data-turbo-track')).toBe(false);
  });

  it('injects once and returns the same promise on repeat calls', () => {
    const first = pagefind.loadPagefind();
    const second = pagefind.loadPagefind();

    expect(second).toBe(first);
    expect(
      document.head.querySelectorAll(`link[href="${CSS_HREF}"]`)
    ).toHaveLength(1);
    expect(
      document.head.querySelectorAll(`script[src="${JS_SRC}"]`)
    ).toHaveLength(1);
  });

  it('resolves true once both assets load and the modal element is defined', async () => {
    const loading = pagefind.loadPagefind();

    injectedCss().dispatchEvent(new Event('load'));
    injectedJs().dispatchEvent(new Event('load'));
    definePagefindModal();

    await expect(loading).resolves.toBe(true);
  });

  it('resolves false — and does not hang — when the module fails to load', async () => {
    // The development condition: /pagefind/ does not exist until `npm run pagefind` runs against
    // build/. If this code waited for whenDefined in each condition, the test would reach its
    // timeout, and `search#open` would do the same in a browser.
    const loading = pagefind.loadPagefind();

    injectedCss().dispatchEvent(new Event('load'));
    injectedJs().dispatchEvent(new Event('error'));

    await expect(loading).resolves.toBe(false);
  });

  // ⚠️ Without this, one flaky request during the idle preload stops the search for the life of
  // the page: `search#open` reads the false result for all time.
  it('loads again after a failure, with new elements', async () => {
    const first = pagefind.loadPagefind();
    injectedCss().dispatchEvent(new Event('load'));
    injectedJs().dispatchEvent(new Event('error'));
    await expect(first).resolves.toBe(false);
    expect(
      document.head.querySelectorAll('script[src$="pagefind-component-ui.js"]')
    ).toHaveLength(0);

    const second = pagefind.loadPagefind();
    expect(second).not.toBe(first);
    injectedCss().dispatchEvent(new Event('load'));
    injectedJs().dispatchEvent(new Event('load'));
    definePagefindModal();
    await expect(second).resolves.toBe(true);
  });

  it('resolves false when the stylesheet fails but the module loads', async () => {
    const loading = pagefind.loadPagefind();

    injectedCss().dispatchEvent(new Event('error'));
    injectedJs().dispatchEvent(new Event('load'));
    definePagefindModal();

    await expect(loading).resolves.toBe(false);
  });
});

describe('preloadPagefindWhenIdle', () => {
  it('loads at the next idle moment when the page has already loaded', () => {
    // The requestIdleCallback stub in the setup file calls its function immediately.
    pagefind.preloadPagefindWhenIdle();

    expect(injectedJs()).not.toBeNull();
  });

  it('schedules only once, however many Search triggers connect', () => {
    const requestIdleCallback = vi.fn();
    window.requestIdleCallback = requestIdleCallback;

    pagefind.preloadPagefindWhenIdle();
    pagefind.preloadPagefindWhenIdle();
    pagefind.preloadPagefindWhenIdle();

    expect(requestIdleCallback).toHaveBeenCalledTimes(1);
  });

  it('passes a timeout so the idle callback cannot be starved indefinitely', () => {
    const requestIdleCallback = vi.fn();
    window.requestIdleCallback = requestIdleCallback;

    pagefind.preloadPagefindWhenIdle();

    expect(requestIdleCallback.mock.calls[0][1]).toEqual({ timeout: 3000 });
  });

  it('falls back to a timeout where requestIdleCallback is missing', () => {
    // Safari has requestIdleCallback only from version 17.
    vi.useFakeTimers();
    delete window.requestIdleCallback;

    pagefind.preloadPagefindWhenIdle();
    expect(injectedJs()).toBeNull();

    vi.advanceTimersByTime(1000);

    expect(injectedJs()).not.toBeNull();
  });

  it('waits for the load event when the page is still loading', () => {
    vi.spyOn(document, 'readyState', 'get').mockReturnValue('loading');

    pagefind.preloadPagefindWhenIdle();
    expect(injectedJs()).toBeNull();

    window.dispatchEvent(new Event('load'));

    expect(injectedJs()).not.toBeNull();
  });
});
