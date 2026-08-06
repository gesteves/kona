/**
 * Sends a call to Plausible if it's available, so tracking is a no-op when the script isn't
 * injected (e.g. in development) instead of a ReferenceError.
 * @param {...*} args - Arguments forwarded to `window.plausible`.
 */
function track(...args) {
  if (typeof window.plausible !== 'function') return;
  window.plausible(...args);
}

/**
 * Tracks a page view, then strips tracking params from the URL.
 * @param {Object} additionalProps - Optional additional properties to include with the pageview.
 */
export function trackPageView(additionalProps = {}) {
  const currentUrl = new URL(window.location.href);
  const searchQuery = currentUrl.searchParams.get('q');

  const params = { u: currentUrl.href };

  if (searchQuery || Object.keys(additionalProps).length > 0) {
    params.props = { ...additionalProps };
    if (searchQuery) {
      params.props.search_query = searchQuery;
    }
  }

  track('pageview', params);
  cleanUpUrl();
}

/**
 * Tracks an event.
 * @param {string} event - The event name to be tracked.
 * @param {Object} props - Additional properties to send with the event.
 */
export function trackEvent(event, props = {}) {
  track(event, { props });
}

/**
 * Tracks an event, then runs a callback exactly once — even if the event can't be sent. Use
 * this when the callback navigates away, which would otherwise cancel the in-flight request.
 * @param {string} event - The event name to be tracked.
 * @param {Object} props - Additional properties to send with the event.
 * @param {Function} done - Callback to run once the event is sent (or times out).
 */
export function trackEventThen(event, props, done) {
  let ran = false;
  const go = () => {
    if (ran) return;
    ran = true;
    done();
  };

  if (typeof window.plausible !== 'function') return go();

  track(event, { props, callback: go });
  // Fallback so navigation isn't blocked if the callback never fires.
  setTimeout(go, 150);
}

let searchTrackingReady = false;

/**
 * Subscribes to the Pagefind modal's shared search instance and forwards each settled query to
 * Plausible as a `Search` event. Subscribes at most once across all callers and navigations;
 * no-ops without setting the flag until the Pagefind Component UI has loaded, so a later call
 * can retry.
 */
export function initSearchTracking() {
  if (searchTrackingReady) return;
  const instance =
    window.PagefindComponents?.getInstanceManager?.().getInstance?.('default');
  if (typeof instance?.on !== 'function') return;
  searchTrackingReady = true;

  let timer;
  let lastTracked = '';
  instance.on('results', (search) => {
    const term = (instance.searchTerm || '').trim();
    if (!term) return;
    const results =
      search?.unfilteredTotalCount ?? search?.results?.length ?? 0;
    // Trailing-debounce, so the query the user settled on is recorded once rather than every
    // keystroke prefix.
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (term === lastTracked) return;
      lastTracked = term;
      trackEvent('Search', { search_query: term, results });
    }, 1200);
  });
}

/** Strips marketing and tracking query parameters from the page URL via replaceState. */
export function cleanUpUrl() {
  const currentUrl = new URL(window.location.href);
  const params = currentUrl.searchParams;

  const paramsToRemove = [
    'ref',
    'source',
    'utm_source',
    'utm_medium',
    'utm_campaign',
    'utm_content',
    'utm_term',
  ];

  let paramRemoved = false;

  paramsToRemove.forEach((param) => {
    if (params.has(param)) {
      params.delete(param);
      paramRemoved = true;
    }
  });

  if (paramRemoved) {
    const cleanURL =
      window.location.origin +
      window.location.pathname +
      (params.toString() ? '?' + params.toString() : '');
    window.history.replaceState({}, document.title, cleanURL);
  }
}
