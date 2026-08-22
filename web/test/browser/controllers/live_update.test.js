import { beforeEach, describe, expect, it, vi } from 'vitest';
import { flushDom, mount } from '../helpers';

// The widget refresh controller, which is the web half of the HTML contract between the two apps
// (refer to the root CLAUDE.md). Two types of element run it, and one boolean gives the difference:
//
//   placeholder — the skeleton on the web side. It has no real content, thus it always fetches on
//                 connect and it removes itself if the fetch fails.
//   fragment    — the api view that replaces the skeleton. It has real content, thus it fetches
//                 only when that content is old, and it KEEPS its content if a fetch fails.
//
// Almost each test below tests that difference, and also the clock at the module level that makes a
// Turbo back or forward restoration visit get new content instead of a stop.

const WIDGET_URL = '/widgets/plausible/pageviews/abc123';
const OTHER_URL = '/widgets/weather/current';
const MIN_REFETCH_MS = 60_000;

const placeholder = (url = WIDGET_URL) =>
  `<div class="pageviews" data-controller="live-update"
        data-live-update-url-value="${url}"
        data-live-update-placeholder-value="true"
        data-action="visibilitychange@document->live-update#handleVisibilityChange"><wa-skeleton></wa-skeleton></div>`;

// data-live-update-placeholder-value is absent, and that is the contract.
const fragment = (url = WIDGET_URL, body = '48 views') =>
  `<div class="pageviews" data-controller="live-update"
        data-live-update-url-value="${url}"
        data-action="visibilitychange@document->live-update#handleVisibilityChange">${body}</div>`;

/** A response with only the three members that the controller reads. */
const respondWith = (body, { ok = true, status = 200 } = {}) => ({
  ok,
  status,
  text: async () => body,
});

let LiveUpdateController;
let fetchMock;
let now;

beforeEach(async () => {
  // The clock (`lastFetchAtByUrl`) is module state and it stays between the tests in a file, which
  // would make each test depend on the tests before it. Reset the registry and import again, thus
  // each test starts with an empty clock.
  vi.resetModules();
  LiveUpdateController = (
    await import('../../../source/javascripts/stimulus/controllers/live_update_controller')
  ).default;

  now = 1_000_000;
  vi.spyOn(Date, 'now').mockImplementation(() => now);

  fetchMock = vi.fn(async () => respondWith(fragment()));
  vi.stubGlobal('fetch', fetchMock);
});

/** Puts new markup in the live document, in the way that a Turbo snapshot render does. */
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
    // This stops a loop. The fragment has the same data-controller, thus it connects immediately
    // when it arrives. The URL is the key of the clock, thus the fragment finds the time of the
    // fetch that added it, and it does nothing. An error here makes the widget send many requests
    // to itself.
    await mountLiveUpdate(placeholder());
    await flushDom();
    await flushDom();

    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('fetches for a fragment whose URL has never been fetched in this document', async () => {
    // A URL with no time counts as old. In practice this occurs when a page starts with markup that
    // already has content, and nothing in the document says how old that content is.
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
    // The placeholder flag and the clock exist to correct this problem. A Turbo restoration visit
    // renders the cached snapshot again, and that snapshot contains the FRAGMENT. It makes no
    // network request. Thus without this code the widget would show the content from the last time
    // that the user left the page, for all time. On a view counter, that looks like a number that
    // goes down.
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

    // A different widget, inside the throttle window of the first one.
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
    // An empty body is the "no data" answer from the api, and not a failure. An Upcoming Races
    // widget whose last race is in the past must go away. Thus this removal has no condition, and
    // each other failure path below is different.
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
    // This is the important failure. A short problem at the origin must never remove content that
    // is already on the screen. That is why the placeholder flag controls the removal, and why the
    // removal does not apply to each element that runs this controller.
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
    // The clock records the ATTEMPT, and not the result.
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
    // This is how it occurs: Turbo replaces the <body> while a widget still waits for the api.
    // Without the abort, the late response would call replaceElement on a node that is not in the
    // document. That does nothing at the best, and it renders old content at the worst.
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
    // A navigation during a request is not a failure, thus it must not start the removal path.
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
    // Without the throttle, one change of the window gets all five home-page widgets again.
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
