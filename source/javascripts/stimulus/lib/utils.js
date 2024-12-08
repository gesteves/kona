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
