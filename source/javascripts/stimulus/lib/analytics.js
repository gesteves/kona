/* global plausible */

/**
 * Sets up the Plausible analytics queue if it doesn't already exist.
 */
function setupPlausibleQueue() {
  window.plausible = window.plausible || function() {
    (window.plausible.q = window.plausible.q || []).push(arguments);
  }
}

/**
 * Product-agnostic function to make a page view tracking call.
 * Currently supports Plausible.
 */
export function trackPageView() {
  setupPlausibleQueue();
  plausible('pageview', { u: window.location.href });
  cleanUpUrl();
}

/**
 * Product-agnostic function to make an event tracking call.
 * Currently supports Plausible.
 * @param {string} event - The event name to be tracked.
 * @param {Object} props - Additional properties to send with the event.
 */
export function trackEvent(event, props = {}) {
  setupPlausibleQueue();
  plausible(event, { props: props });
}

/**
 * Removes specific UTM parameters and other query parameters from the page URL.
 * This function modifies the current URL by removing marketing and tracking parameters,
 * then updates the browser's history state to reflect the clean URL.
 */
export function cleanUpUrl() {
  const currentUrl = new URL(window.location.href);
  const params = currentUrl.searchParams;

  // List of query parameters to remove
  const paramsToRemove = [
      'ref',
      'source',
      'utm_source',
      'utm_medium',
      'utm_campaign',
      'utm_content',
      'utm_term'
  ];

  paramsToRemove.forEach(param => {
      params.delete(param);
  });

  const cleanURL = window.location.origin + window.location.pathname + (params.toString() ? '?' + params.toString() : '');
  window.history.replaceState({}, document.title, cleanURL);
}
