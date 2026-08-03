import { beforeEach, describe, expect, it, vi } from 'vitest';

// The on-demand loader for Pagefind's Component UI. Two behaviours here are load-bearing and easy
// to break silently:
//
//   1. the stylesheet is INSERTED BEFORE the first existing one, never appended — the dark-mode
//      --pf-* remap in _pagefind.scss wins on source order alone, so appending makes the search
//      modal render permanently light at night;
//   2. a failed module load must still SETTLE — `customElements.whenDefined` for a script that
//      404'd never resolves, which would hang `search#open` forever in development.

const CSS_HREF = '/pagefind/pagefind-component-ui.css';
const JS_SRC = '/pagefind/pagefind-component-ui.js';

let pagefind;

const injectedCss = () =>
  document.head.querySelector(`link[href="${CSS_HREF}"]`);
const injectedJs = () => document.head.querySelector(`script[src="${JS_SRC}"]`);
// The custom element registry belongs to the jsdom instance, which is shared by every test in
// this file — unlike the module registry, vi.resetModules() cannot clear it, and a second
// define() of the same name throws. So define once and let later tests reuse it.
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
  // `loading` and `idleScheduled` are module state — the memoization under test. Re-import per
  // test so each one starts unloaded.
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

    // Source order is the entire mechanism by which the dark-mode override wins. Append instead
    // of insert and the modal goes light in dark mode, with nothing to show for it in the DOM
    // except this ordering.
    expect(stylesheets()).toEqual([CSS_HREF, '/stylesheets/site.css']);
  });

  it('appends cleanly when there is no existing stylesheet', () => {
    expect(() => pagefind.loadPagefind()).not.toThrow();
    expect(injectedCss()).not.toBeNull();
  });

  it('marks neither element with data-turbo-track, so both survive navigation', () => {
    // Turbo strips stylesheets marked `dynamic` that are missing from the incoming <head> — and
    // no rendered page will ever contain these, so marking them would delete them on the first
    // navigation.
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
    // The development case: /pagefind/ does not exist until `npm run pagefind` has run against
    // build/. If this awaited whenDefined regardless, the test would time out — which is exactly
    // what `search#open` would do in a browser.
    const loading = pagefind.loadPagefind();

    injectedCss().dispatchEvent(new Event('load'));
    injectedJs().dispatchEvent(new Event('error'));

    await expect(loading).resolves.toBe(false);
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
    // The setup file's requestIdleCallback stub runs its callback synchronously.
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
    // Safari only gained requestIdleCallback in 17.
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
