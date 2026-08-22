// The time that a toast stays on the screen before it goes away, in milliseconds.
const TOAST_DURATION_MS = 3000;

/**
 * Shows a toast message in the Web Awesome <wa-toast> stack.
 * @param {string} message The text of the message.
 * @param {string} status The type of the message: 'success', or each other value, which gives
 *   'danger'.
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
 * Puts the nodes from an HTML string in place of an element.
 * @param {String} html An HTML string.
 * @param {Element} element The element to replace.
 */
export function replaceElement(html, element) {
  const tempContainer = document.createElement('div');
  tempContainer.innerHTML = html;
  element.replaceWith(...tempContainer.childNodes);
}

/**
 * The canonical URL of the current page: the href of the <link rel="canonical"> if the page has
 * one, or the window location.
 * @returns {String} The canonical URL.
 */
export function canonicalUrl() {
  return (
    document.querySelector('link[rel="canonical"]')?.href ||
    window.location.href
  );
}

/**
 * Changes the href of an anchor into an absolute URL. It accepts an href that is absent, one with
 * a fragment only (#…), one with no protocol (//…), one that starts at the root (/…), and one that
 * is already absolute.
 * @param {String|null} href The value of an href attribute.
 * @returns {String} The absolute URL. For an href that is absent, it gives the current page.
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
