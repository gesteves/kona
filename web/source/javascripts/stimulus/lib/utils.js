// How long a toast stays on screen before auto-dismissing, in milliseconds.
const TOAST_DURATION_MS = 3000;

/**
 * Shows a toast notification via the Web Awesome <wa-toast> stack.
 * @param {string} message The text for the notification
 * @param {string} status The type of notification ('success' or anything else → 'danger')
 */
export function sendNotification(message, status = 'success') {
  const toast = document.querySelector('wa-toast');
  if (!toast?.create) {
    return;
  }
  const variant = status === 'success' ? 'success' : 'danger';
  toast.create(message, { variant, duration: TOAST_DURATION_MS });
}

/**
 * Replaces an element with the nodes parsed from an HTML string.
 * @param {String} html An HTML string.
 * @param {Element} element The element to replace.
 */
export function replaceElement(html, element) {
  const tempContainer = document.createElement('div');
  tempContainer.innerHTML = html;
  element.replaceWith(...tempContainer.childNodes);
}

/**
 * The canonical URL for the current page: the <link rel="canonical"> href when present,
 * falling back to the window location.
 * @returns {String} The canonical URL.
 */
export function canonicalUrl() {
  return (
    document.querySelector('link[rel="canonical"]')?.href ||
    window.location.href
  );
}

/**
 * Resolves an anchor's href to an absolute URL. Handles missing, anchor-only (#…),
 * protocol-relative (//…), root-relative (/…), and already-absolute hrefs.
 * @param {String|null} href An href attribute value.
 * @returns {String} The absolute URL (the current page for a missing href).
 */
export function absoluteUrl(href) {
  if (!href) {
    return window.location.href;
  } else if (href.startsWith('#')) {
    return window.location.origin + window.location.pathname + href;
  } else if (href.startsWith('//')) {
    return href;
  } else if (href.startsWith('/')) {
    return window.location.origin + href;
  } else {
    return href;
  }
}
