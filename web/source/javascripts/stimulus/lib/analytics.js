/**
 * Calls Plausible if it is available. Thus the tracking does nothing when the page has no such
 * script, for example in development, and it does not raise a ReferenceError.
 * @param {...*} args - The arguments that go to `window.plausible`.
 */
function track(...args) {
  if (typeof window.plausible !== 'function') return;
  window.plausible(...args);
}

/**
 * Records a page view, then removes the tracking parameters from the URL.
 * @param {Object} additionalProps - More properties for the page view. They are optional.
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
 * Records an event.
 * @param {string} event - The name of the event.
 * @param {Object} props - More properties to send with the event.
 */
export function trackEvent(event, props = {}) {
  track(event, { props });
}

/**
 * Records an event, then calls a function one time only, and it calls that function even if the
 * event does not go out. Use this when the function navigates away, which would stop the request.
 * @param {string} event - The name of the event.
 * @param {Object} props - More properties to send with the event.
 * @param {Function} done - The function to call after the event goes out, or after the timeout.
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
  // This lets the navigation continue if the function never runs.
  setTimeout(go, 150);
}

let searchTrackingReady = false;

/**
 * Reads the shared search instance of the Pagefind modal and sends each complete query to
 * Plausible as a `Search` event. It does this one time for all the callers and all the
 * navigations. It does nothing, and it does not set the flag, until the Pagefind Component UI
 * loads. Thus a later call can try again.
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
    // This waits until the user stops. Thus the code records the final query one time, and not the
    // text after each keystroke.
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (term === lastTracked) return;
      lastTracked = term;
      trackEvent('Search', { search_query: term, results });
    }, 1200);
  });
}

/** Removes the marketing and tracking query parameters from the page URL, with replaceState. */
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
    // ⚠️ Keep the state that exists. Turbo holds its restorationIdentifier in the history state,
    // and this code runs at each turbo:load. If it writes {} for a URL with a utm_ or ref
    // parameter, the scroll position and the snapshot do not come back on a back navigation, and
    // there is no message.
    window.history.replaceState(window.history.state, '', cleanURL);
  }
}
