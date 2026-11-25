const TOAST_DURATION_MS = 3000;

/**
 * Shows a toast message in the Web Awesome <wa-toast> stack.
 * @param {string} status 'success', or each other value, which gives the 'danger' variant.
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
 * Puts a stylesheet element in the head, before the first stylesheet that is there. Thus each
 * stylesheet of the site comes after it in the source order. With no stylesheet in the head, the
 * element goes at the end.
 * @param {HTMLLinkElement} link
 */
export function insertBeforeFirstStylesheet(link) {
  document.head.insertBefore(
    link,
    document.head.querySelector('link[rel="stylesheet"]')
  );
}

/** Puts the nodes from an HTML string in place of an element. */
export function replaceElement(html, element) {
  const tempContainer = document.createElement('div');
  tempContainer.innerHTML = html;
  element.replaceWith(...tempContainer.childNodes);
}

/**
 * The canonical URL of the current page: the href of the <link rel="canonical"> if the page has
 * one, or the window location.
 * @returns {string}
 */
export function canonicalUrl() {
  return (
    document.querySelector('link[rel="canonical"]')?.href ||
    window.location.href
  );
}

/**
 * Changes the href of an anchor into an absolute URL. It adds the origin to an href that starts at
 * the root (/…), and the origin and the path to a fragment (#…). Each other href comes back with
 * no change, and that includes one with no protocol (//…).
 * @param {string|null} href The value of an href attribute.
 * @returns {string} The URL. For an href that is absent, it gives the current page.
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
