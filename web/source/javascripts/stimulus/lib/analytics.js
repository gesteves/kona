/**
 * Sends a call to Plausible if it's available. The queue stub and configuration
 * are set up inline in the page head (partials/_analytics.html.erb) before the
 * deferred script loads, so here we only need to guard against Plausible being
 * absent (e.g. in development, where the script isn't injected), which turns
 * every tracking call into a no-op instead of a ReferenceError.
 * @param {...*} args - Arguments forwarded to `window.plausible`.
 */
function track(...args) {
  if (typeof window.plausible !== 'function') return;
  window.plausible(...args);
}

/**
 * Product-agnostic function to make a page view tracking call.
 * Currently supports Plausible.
 * @param {Object} additionalProps - Optional additional properties to include with the pageview.
 */
export function trackPageView(additionalProps = {}) {
  const currentUrl = new URL(window.location.href);
  const searchQuery = currentUrl.searchParams.get('q');

  const params = { u: currentUrl.href };

  // Combine search query with any additional props
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
 * Product-agnostic function to make an event tracking call.
 * Currently supports Plausible.
 * @param {string} event - The event name to be tracked.
 * @param {Object} props - Additional properties to send with the event.
 */
export function trackEvent(event, props = {}) {
  track(event, { props });
}

/**
 * Tracks an event and then runs a callback, guaranteeing the callback runs even
 * if the event can't be sent. Use this when the callback navigates the page away
 * (e.g. `window.location.href = …`), which would otherwise cancel an in-flight
 * tracking request. Relies on Plausible's `callback` option, with a short timeout
 * as a fallback in case the callback never fires (or Plausible isn't loaded).
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
 * Subscribes to the Pagefind modal's shared search instance and forwards each
 * settled query to Plausible as a `Search` event. Idempotent and guarded by a
 * module-level flag, so it subscribes exactly once no matter how many "Search"
 * buttons call it or how many Turbo navigations occur. No-ops (leaving the flag
 * unset, so a later call can retry) until the Pagefind Component UI has loaded —
 * e.g. in development, where `/pagefind/` doesn't exist.
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
    // Trailing-debounce so we record the query the user settled on, once —
    // not every keystroke prefix (`z`, `zw`, `zwi`, …).
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (term === lastTracked) return;
      lastTracked = term;
      trackEvent('Search', { search_query: term, results });
    }, 1200);
  });
}

/**
 * Removes specific UTM parameters and other query parameters from the page URL.
 * This function modifies the current URL by removing marketing and tracking parameters,
 * then updates the browser's history state to reflect the clean URL.
 */
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
