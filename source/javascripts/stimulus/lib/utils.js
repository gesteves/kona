/**
 * Dispatches a custom `notify` event to trigger a notification
 * @param {string} message The text for the notification
 * @param {string} status The type of notification
 */
export function sendNotification (message, status = 'success') {
  const event = new CustomEvent('notify', {
    detail: {
      message: message,
      status: status
    }
  });
  document.body.dispatchEvent(event);
}

/**
 * Prepends the given HTML to the element
 * @param {String} html An HTML string.
 * @param {Element} element The element to prepend to.
 */
export function prependToElement(html, element) {
  const tempContainer = document.createElement("div");
  tempContainer.innerHTML = html;
  while (tempContainer.firstChild) {
    element.prepend(tempContainer.firstChild);
  }
}

/**
 * Appends the given HTML to the element
 * @param {String} html An HTML string.
 * @param {Element} element The element to append to.
 */
export function appendToElement(html, element) {
  const tempContainer = document.createElement("div");
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
  const tempContainer = document.createElement("div");
  tempContainer.innerHTML = html;
  while (tempContainer.firstChild) {
    element.replaceWith(tempContainer.firstChild);
  }
}
