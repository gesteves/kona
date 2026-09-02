import { beforeEach, describe, expect, it, vi } from 'vitest';

// Each export here calls Plausible, and it does nothing when Plausible is absent. The page head
// makes the queue stub before the deferred script loads. Thus the check is for the conditions with
// no script at all: development, and each page that a build makes with no PLAUSIBLE_SCRIPT_URL. A
// ReferenceError there would stop the code that called it, that is, a share click or a page view.

let analytics;

beforeEach(async () => {
  // `searchTrackingReady` is module state. A new import for each test keeps the "one subscribe
  // only" tests of initSearchTracking separate from each other.
  vi.resetModules();
  analytics =
    await import('../../../source/javascripts/stimulus/lib/analytics');
});

describe('trackPageView', () => {
  it('does not throw when Plausible is absent', () => {
    expect(() => analytics.trackPageView()).not.toThrow();
  });

  it('sends a pageview carrying the current URL', () => {
    window.plausible = vi.fn();
    window.history.replaceState({}, '', '/2026/01/01/hello');

    analytics.trackPageView();

    expect(window.plausible).toHaveBeenCalledWith('pageview', {
      u: 'http://localhost:3000/2026/01/01/hello',
    });
  });

  it('omits props entirely when there is nothing to report', () => {
    window.plausible = vi.fn();

    analytics.trackPageView();

    expect(window.plausible.mock.calls[0][1]).not.toHaveProperty('props');
  });

  it('sends no props for a page with a query and no caller props', () => {
    window.plausible = vi.fn();
    window.history.replaceState({}, '', '/search?q=marathon');

    analytics.trackPageView();

    expect(window.plausible.mock.calls[0][1].props).toBeUndefined();
  });

  it('reads the query before scrubbing the URL', () => {
    // trackPageView calls cleanUpUrl() at the end. In the other order, a visit with ?utm_source=…
    // would go to the analytics with a URL that the code already changed.
    window.plausible = vi.fn();
    window.history.replaceState({}, '', '/search?q=marathon&utm_source=news');

    analytics.trackPageView();

    expect(window.plausible.mock.calls[0][1].u).toContain('utm_source=news');
    expect(window.location.search).toBe('?q=marathon');
  });
});

describe('cleanUpUrl', () => {
  it('strips every tracking param it knows about', () => {
    const params =
      'ref=a&source=b&utm_source=c&utm_medium=d&utm_campaign=e&utm_content=f&utm_term=g';
    window.history.replaceState({}, '', `/post?${params}`);

    analytics.cleanUpUrl();

    expect(window.location.href).toBe('http://localhost:3000/post');
  });

  it('keeps params that are not tracking params', () => {
    window.history.replaceState({}, '', '/post?q=hi&utm_source=news&page=2');

    analytics.cleanUpUrl();

    expect(window.location.search).toBe('?q=hi&page=2');
  });

  it('leaves the history alone when there is nothing to strip', () => {
    // The check before the replaceState is important: a replaceState with no check would change the
    // history at each Turbo page view, for no purpose.
    window.history.replaceState({}, '', '/post?q=hi');
    const replaceState = vi.spyOn(window.history, 'replaceState');

    analytics.cleanUpUrl();

    expect(replaceState).not.toHaveBeenCalled();
  });

  // Turbo holds its restorationIdentifier in the history state, and this code runs at each
  // turbo:load. A new {} removes it, and the scroll position and the snapshot then do not come back
  // on a back navigation, for each page that a visitor reaches with a utm_ or ref parameter.
  it('preserves the existing history state', () => {
    const turboState = { turbo: { restorationIdentifier: 'abc123' } };
    window.history.replaceState(turboState, '', '/post?utm_source=news');

    analytics.cleanUpUrl();

    expect(window.history.state).toEqual(turboState);
    expect(window.location.search).toBe('');
  });
});

describe('trackEvent', () => {
  it('does not throw when Plausible is absent', () => {
    expect(() =>
      analytics.trackEvent('Share', { via: 'Native' })
    ).not.toThrow();
  });

  it('nests the properties under props, as the Plausible API expects', () => {
    window.plausible = vi.fn();

    analytics.trackEvent('Share', { via: 'Native' });

    expect(window.plausible).toHaveBeenCalledWith('Share', {
      props: { via: 'Native' },
    });
  });

  it('defaults to empty props', () => {
    window.plausible = vi.fn();

    analytics.trackEvent('Search');

    expect(window.plausible).toHaveBeenCalledWith('Search', { props: {} });
  });
});

describe('trackEventThen', () => {
  it('runs the callback immediately when Plausible is absent', () => {
    // The function navigates the page. It must run with the analytics and without them. Without
    // this rule, a mailto: share link would do nothing in development, and give no message.
    const done = vi.fn();

    analytics.trackEventThen('Share', {}, done);

    expect(done).toHaveBeenCalledTimes(1);
  });

  it('runs the callback from Plausible’s own callback option', () => {
    window.plausible = vi.fn((_event, options) => options.callback());
    const done = vi.fn();

    analytics.trackEventThen('Share', { via: 'Email' }, done);

    expect(window.plausible.mock.calls[0][1].props).toEqual({ via: 'Email' });
    expect(done).toHaveBeenCalledTimes(1);
  });

  it('falls back to a timeout when Plausible never calls back', () => {
    vi.useFakeTimers();
    window.plausible = vi.fn(); // accepts the call, never invokes the callback
    const done = vi.fn();

    analytics.trackEventThen('Share', {}, done);
    expect(done).not.toHaveBeenCalled();

    vi.advanceTimersByTime(150);

    expect(done).toHaveBeenCalledTimes(1);
  });

  it('runs the callback exactly once when both the callback and the timeout fire', () => {
    // Two navigations is the failure that this test checks for.
    vi.useFakeTimers();
    window.plausible = vi.fn((_event, options) => options.callback());
    const done = vi.fn();

    analytics.trackEventThen('Share', {}, done);
    vi.advanceTimersByTime(1000);

    expect(done).toHaveBeenCalledTimes(1);
  });
});

describe('initSearchTracking', () => {
  /** Replaces the shared search instance of the Pagefind Component UI. */
  const stubPagefindInstance = (instance) => {
    window.PagefindComponents = {
      getInstanceManager: () => ({ getInstance: () => instance }),
    };
  };

  it('no-ops when the Pagefind Component UI has not loaded', () => {
    expect(() => analytics.initSearchTracking()).not.toThrow();
  });

  it('stays retryable after a no-op, rather than latching off', () => {
    // Each Search button calls this on connect, much earlier than the load of the JavaScript of
    // the modal. If the first call set the flag, the search tracking would never start on a page.
    analytics.initSearchTracking();

    const on = vi.fn();
    stubPagefindInstance({ on, searchTerm: '' });
    analytics.initSearchTracking();

    expect(on).toHaveBeenCalledTimes(1);
  });

  it('subscribes exactly once no matter how many triggers call it', () => {
    const on = vi.fn();
    stubPagefindInstance({ on, searchTerm: '' });

    analytics.initSearchTracking();
    analytics.initSearchTracking();
    analytics.initSearchTracking();

    expect(on).toHaveBeenCalledTimes(1);
  });

  it('reports the query the user settled on, not every keystroke prefix', () => {
    vi.useFakeTimers();
    window.plausible = vi.fn();
    const instance = { on: vi.fn(), searchTerm: '' };
    stubPagefindInstance(instance);
    analytics.initSearchTracking();
    const onResults = instance.on.mock.calls[0][1];

    // The user types "zwift", one character at a time.
    for (const term of ['z', 'zw', 'zwi', 'zwif', 'zwift']) {
      instance.searchTerm = term;
      onResults({ unfilteredTotalCount: 3 });
      vi.advanceTimersByTime(100);
    }
    vi.advanceTimersByTime(1200);

    expect(window.plausible).toHaveBeenCalledTimes(1);
    expect(window.plausible).toHaveBeenCalledWith('Search', {
      props: { search_query: 'zwift', results: 3 },
    });
  });

  it('ignores a blank or whitespace-only term', () => {
    vi.useFakeTimers();
    window.plausible = vi.fn();
    const instance = { on: vi.fn(), searchTerm: '   ' };
    stubPagefindInstance(instance);
    analytics.initSearchTracking();

    instance.on.mock.calls[0][1]({ unfilteredTotalCount: 0 });
    vi.advanceTimersByTime(2000);

    expect(window.plausible).not.toHaveBeenCalled();
  });

  it('does not report the same term twice', () => {
    vi.useFakeTimers();
    window.plausible = vi.fn();
    const instance = { on: vi.fn(), searchTerm: 'zwift' };
    stubPagefindInstance(instance);
    analytics.initSearchTracking();
    const onResults = instance.on.mock.calls[0][1];

    onResults({ unfilteredTotalCount: 3 });
    vi.advanceTimersByTime(2000);
    onResults({ unfilteredTotalCount: 3 });
    vi.advanceTimersByTime(2000);

    expect(window.plausible).toHaveBeenCalledTimes(1);
  });

  it('trims the term before reporting it', () => {
    vi.useFakeTimers();
    window.plausible = vi.fn();
    const instance = { on: vi.fn(), searchTerm: '  zwift  ' };
    stubPagefindInstance(instance);
    analytics.initSearchTracking();

    instance.on.mock.calls[0][1]({ unfilteredTotalCount: 1 });
    vi.advanceTimersByTime(2000);

    expect(window.plausible.mock.calls[0][1].props.search_query).toBe('zwift');
  });

  it('falls back to the result count, then to zero', () => {
    vi.useFakeTimers();
    window.plausible = vi.fn();
    const instance = { on: vi.fn(), searchTerm: 'a' };
    stubPagefindInstance(instance);
    analytics.initSearchTracking();
    const onResults = instance.on.mock.calls[0][1];

    onResults({ results: [1, 2] }); // no unfilteredTotalCount
    vi.advanceTimersByTime(2000);
    instance.searchTerm = 'b';
    onResults({}); // neither
    vi.advanceTimersByTime(2000);

    expect(window.plausible.mock.calls[0][1].props.results).toBe(2);
    expect(window.plausible.mock.calls[1][1].props.results).toBe(0);
  });
});
