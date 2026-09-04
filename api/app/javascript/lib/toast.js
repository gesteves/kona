/**
 * The `<wa-toast>` stack of the admin layout.
 *
 * ⚠️ The layout renders that stack one time, outside `<wa-page>`, thus each page and each dialog
 * can show a message and nothing on the page moves.
 */

// The id of the stack in the admin layout.
const TOAST_STACK_ID = "notifications";

/**
 * Shows one message in the toast stack.
 * @param {string} message The words of the message.
 * @param {string} [variant] "success", or "danger" for a message that says an action failed.
 */
export function toast(message, variant = "success") {
  const stack = document.getElementById(TOAST_STACK_ID);
  // The stack is a custom element, thus `create` is absent until the browser upgrades it.
  if (!message || !stack?.create) return;

  // ⚠️ It sends no `duration`. The default of <wa-toast-item> is the time on screen, and the flash
  // that the layout renders takes that same default. Thus one value covers both.
  stack.create(message, { variant });
}
