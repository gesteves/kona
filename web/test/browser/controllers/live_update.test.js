import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushDom, mount } from '../helpers';

// The widget refresh controller — the web half of the cross-app HTML contract (root CLAUDE.md).
// Two kinds of element run it and the difference is one boolean:
//
//   placeholder — the web-side skeleton. No real content, so it always fetches on connect and
//                 collapses itself if the fetch fails.
//   fragment    — the api view that replaces it. Real content, so it fetches only when that
//                 content is stale, and KEEPS what it has on a failed fetch.
//
// Nearly every test below is really a test of that split, plus the module-scoped clock that makes
// a Turbo back/forward restoration visit refresh instead of freezing.

const WIDGET_URL = '/widgets/plausible/pageviews/abc123';
const OTHER_URL = '/widgets/weather/current';
const MIN_REFETCH_MS = 60_000;

const placeholder = (url = WIDGET_URL) =>
  `<div class="pageviews" data-controller="live-update"
        data-live-update-url-value="${url}"
        data-live-update-placeholder-value="true"
        data-action="visibilitychange@document->live-update#handleVisibilityChange"><wa-skeleton></wa-skeleton></div>`;

// Note the absence of data-live-update-placeholder-value: that omission is the contract.
const fragment = (url = WIDGET_URL, body = '48 views') =>
  `<div class="pageviews" data-controller="live-update"
        data-live-update-url-value="${url}"
        data-action="visibilitychange@document->live-update#handleVisibilityChange">${body}</div>`;

/** A response with only the three members the controller actually reads. */
const respondWith = (body, { ok = true, status = 200 } = {}) => ({
  ok,
  status,
  text: async () => body,
});

let LiveUpdateController;
let fetchMock;
let now;

beforeEach(async () => {
  // The clock (`lastFetchAtByUrl`) is module state and survives between tests in a file, which
  // would make each test depend on its predecessors. Reset the registry and re-import so every
  // test starts from an empty clock.
  vi.resetModules();
  LiveUpdateController = (
    await import('../../../source/javascripts/stimulus/controllers/live_update_controller')
  ).default;

  now = 1_000_000;
  vi.spyOn(Date, 'now').mockImplementation(() => now);

  fetchMock = vi.fn(async () => respondWith(fragment()));
  vi.stubGlobal('fetch', fetchMock);
});

/** Renders new markup into the live document, the way a Turbo snapshot render does. */
const render = async (html) => {
  document.body.innerHTML = html;
  await flushDom();
};

const mountLiveUpdate = (html) =>
  mount('live-update', LiveUpdateController, html);

describe('on connect', () => {
  it('fetches for a placeholder and swaps in the fragment', async () => {
    fetchMock.mockResolvedValue(respondWith(fragment(WIDGET_URL, '48 views')));

    await mountLiveUpdate(placeholder());
    await flushDom();

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe(WIDGET_URL);
    expect(document.body.textContent).toContain('48 views');
    expect(document.querySelector('wa-skeleton')).toBeNull();
  });

  it('does not refetch the fragment it just swapped in', async () => {
    // The loop guard. The fragment carries the same data-controller, so it connects the instant
    // it lands; keying the clock by URL means it finds the inserting fetch's own timestamp
    // already recorded, and stays put. Get this wrong and the widget self-DDoSes.
    await mountLiveUpdate(placeholder());
    await flushDom();
    await flushDom();

    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('fetches for a fragment whose URL has never been fetched in this document', async () => {
    // Unknown counts as stale. In practice this is the case where a page is entered with markup
    // that already holds content — nothing in this document vouches for how old it is.
    await mountLiveUpdate(fragment());

    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('does not fetch for a fragment whose content is under a minute old', async () => {
    await mountLiveUpdate(placeholder());
    await flushDom();
    fetchMock.mockClear();

    now += MIN_REFETCH_MS - 1;
    await render(fragment());

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('fetches for a restored fragment once its content is a minute old', async () => {
    // This is the bug the placeholder/clock split exists to fix. A Turbo restoration visit
    // re-renders the cached snapshot — which contains the FRAGMENT — and issues no network
    // request of its own, so without this the widget would show whatever it showed when the user
    // last left the page, indefinitely. On a view counter that reads as the number going down.
    await mountLiveUpdate(placeholder());
    await flushDom();
    fetchMock.mockClear();

    now += MIN_REFETCH_MS;
    await render(fragment());

    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('throttles per URL, so one widget does not suppress another', async () => {
    await mountLiveUpdate(placeholder(WIDGET_URL));
    await flushDom();
    fetchMock.mockClear();

    // A different widget, well inside the throttle window for the first one.
    await render(fragment(OTHER_URL));

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe(OTHER_URL);
  });

  it('ignores a placeholder with no URL rather than fetching the current page', async () => {
    await mountLiveUpdate(
      '<div data-controller="live-update" data-live-update-placeholder-value="true"></div>'
    );

    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe('on an empty response', () => {
  it('removes a placeholder', async () => {
    fetchMock.mockResolvedValue(respondWith(''));

    await mountLiveUpdate(placeholder());
    await flushDom();

    expect(document.querySelector('.pageviews')).toBeNull();
  });

  it('removes a rendered fragment too', async () => {
    // An empty body is the api's authoritative "no data" answer, not a failure — an Upcoming
    // Races widget whose last race has passed is supposed to disappear. So this one collapse is
    // unconditional, unlike every other failure path below.
    fetchMock.mockResolvedValue(respondWith('   \n  '));

    await mountLiveUpdate(fragment());
    await flushDom();

    expect(document.querySelector('.pageviews')).toBeNull();
  });
});

describe('when the fetch fails', () => {
  beforeEach(() => {
    vi.spyOn(console, 'error').mockImplementation(() => {});
  });

  it('collapses a placeholder on a non-2xx, rather than leaving a stuck skeleton', async () => {
    fetchMock.mockResolvedValue(respondWith('', { ok: false, status: 502 }));

    await mountLiveUpdate(placeholder());
    await flushDom();

    expect(document.querySelector('.pageviews')).toBeNull();
  });

  it('collapses a placeholder on a network error', async () => {
    fetchMock.mockRejectedValue(new TypeError('Failed to fetch'));

    await mountLiveUpdate(placeholder());
    await flushDom();

    expect(document.querySelector('.pageviews')).toBeNull();
  });

  it('KEEPS a rendered fragment on a non-2xx', async () => {
    // The regression that matters. A transient origin blip must never destroy content that is
    // already on screen — the whole reason the collapse behavior is tied to the placeholder flag
    // instead of applying to everything running this controller.
    fetchMock.mockResolvedValue(respondWith('', { ok: false, status: 502 }));

    await mountLiveUpdate(fragment(WIDGET_URL, '48 views'));
    await flushDom();

    expect(document.querySelector('.pageviews')).not.toBeNull();
    expect(document.querySelector('.pageviews').textContent).toBe('48 views');
  });

  it('KEEPS a rendered fragment on a network error', async () => {
    fetchMock.mockRejectedValue(new TypeError('Failed to fetch'));

    await mountLiveUpdate(fragment(WIDGET_URL, '48 views'));
    await flushDom();

    expect(document.querySelector('.pageviews').textContent).toBe('48 views');
  });

  it('holds the throttle after a failure, so a dead endpoint is not retried on every trigger', async () => {
    // The clock records the ATTEMPT, not the outcome.
    fetchMock.mockRejectedValue(new TypeError('Failed to fetch'));

    await mountLiveUpdate(fragment());
    await flushDom();
    fetchMock.mockClear();

    now += MIN_REFETCH_MS - 1;
    await render(fragment());

    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe('request lifecycle', () => {
  it('aborts an in-flight request when the element leaves the DOM', async () => {
    // How this happens for real: Turbo swaps the <body> out from under a widget that is still
    // waiting on the api. Without the abort, the late response would call replaceElement on a
    // detached node — a silent no-op on a good day, and a stale render on a bad one.
    let capturedSignal;
    fetchMock.mockImplementation(async (_url, options) => {
      capturedSignal = options.signal;
      return new Promise(() => {}); // never settles
    });

    const { element } = await mountLiveUpdate(placeholder());
    expect(capturedSignal.aborted).toBe(false);

    element.remove();
    await flushDom();

    expect(capturedSignal.aborted).toBe(true);
  });

  it('swallows an abort without collapsing the placeholder', async () => {
    // A navigation mid-flight is not a failure, so it must not trigger the collapse path.
    const consoleError = vi
      .spyOn(console, 'error')
      .mockImplementation(() => {});
    const abortError = new Error('The operation was aborted.');
    abortError.name = 'AbortError';
    fetchMock.mockRejectedValue(abortError);

    await mountLiveUpdate(placeholder());
    await flushDom();

    expect(document.querySelector('.pageviews')).not.toBeNull();
    expect(consoleError).not.toHaveBeenCalled();
  });

  it('supersedes an in-flight request when a newer one starts', async () => {
    const signals = [];
    fetchMock.mockImplementation(async (_url, options) => {
      signals.push(options.signal);
      return new Promise(() => {});
    });

    const { controller } = await mountLiveUpdate(placeholder());
    now += MIN_REFETCH_MS;
    controller.fetchAndUpdateContent();
    await flushDom();

    expect(signals).toHaveLength(2);
    expect(signals[0].aborted).toBe(true);
    expect(signals[1].aborted).toBe(false);
  });
});

describe('handleVisibilityChange', () => {
  it('refetches a stale fragment when the tab becomes visible', async () => {
    await mountLiveUpdate(placeholder());
    await flushDom();
    fetchMock.mockClear();

    now += MIN_REFETCH_MS;
    document.dispatchEvent(new Event('visibilitychange'));
    await flushDom();

    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('does nothing while the content is fresh', async () => {
    // Without the throttle, one alt-tab refetches all five home-page widgets at once.
    await mountLiveUpdate(placeholder());
    await flushDom();
    fetchMock.mockClear();

    document.dispatchEvent(new Event('visibilitychange'));
    await flushDom();

    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('does nothing when the page is being hidden', async () => {
    await mountLiveUpdate(placeholder());
    await flushDom();
    fetchMock.mockClear();

    now += MIN_REFETCH_MS;
    vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('hidden');
    document.dispatchEvent(new Event('visibilitychange'));
    await flushDom();

    expect(fetchMock).not.toHaveBeenCalled();
  });
});
