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
 * Prepends the given HTML to the element
 * @param {String} html An HTML string.
 * @param {Element} element The element to prepend to.
 */
export function prependToElement(html, element) {
  const tempContainer = document.createElement('div');
  tempContainer.innerHTML = html;
  element.prepend(...tempContainer.childNodes);
}

/**
 * Appends the given HTML to the element
 * @param {String} html An HTML string.
 * @param {Element} element The element to append to.
 */
export function appendToElement(html, element) {
  const tempContainer = document.createElement('div');
  tempContainer.innerHTML = html;
  while (tempContainer.firstChild) {
    element.appendChild(tempContainer.firstChild);
  }
}

/**
 * Replace the given element with the given HTML
 * @param {String} html An HTML string.
 * @param {Element} element The element to replace.
 */
export function replaceElement(html, element) {
  const tempContainer = document.createElement('div');
  tempContainer.innerHTML = html;
  element.replaceWith(...tempContainer.childNodes);
}
