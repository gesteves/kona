import { Controller } from '@hotwired/stimulus';
import { prependToElement } from '../lib/utils';
import Handlebars from 'handlebars';

const AUTO_DISMISS_MS = 2000;

/**
 * Shows transient toast notifications dispatched as `notify` events. Only one is shown at a
 * time: a new notification dismisses whatever is already on screen. Each notification fades in,
 * auto-dismisses after a short delay (or when clicked), and is removed from the DOM once it has
 * faded out.
 * @extends Controller
 */
export default class extends Controller {
  static classes = ['transparent', 'closed'];
  static targets = ['container', 'notification', 'template'];

  connect() {
    // Every pending timer, keyed by its notification element, so they can all be cancelled when
    // the notification is removed (or the controller disconnects). Keeps timers bounded — this
    // element is `data-turbo-permanent`, so the controller effectively never disconnects.
    this.timers = new Map();
  }

  disconnect() {
    this.timers.forEach((ids) => ids.forEach((id) => clearTimeout(id)));
    this.timers.clear();
  }

  /**
   * Adds a new notification, replacing any already on screen.
   * @param {Event} event Custom `notify` event with `{ message, status }` detail.
   */
  add(event) {
    const { message, status } = event.detail;
    const render = Handlebars.compile(this.templateTarget.innerHTML);
    const markup = render({
      message,
      status,
      showSuccessIcon: this.showSuccessIcon(status),
      showWarningIcon: !this.showSuccessIcon(status),
    });

    this.notificationTargets.forEach((notification) =>
      this.dismiss(notification)
    );
    prependToElement(markup, this.containerTarget);
    this.reveal(this.notificationTargets[0]);
  }

  /**
   * Fades a freshly-added notification in and arms its auto-dismiss timer.
   * @param {HTMLElement} notification
   */
  reveal(notification) {
    // Force the browser to commit the initial transparent state so dropping the class animates
    // instead of snapping straight to opaque.
    void notification.offsetWidth;
    notification.classList.remove(this.transparentClass);
    this.track(
      notification,
      setTimeout(() => this.dismiss(notification), AUTO_DISMISS_MS)
    );
  }

  /**
   * Fades a notification out, then removes it from the DOM. Idempotent.
   * @param {HTMLElement} notification
   */
  dismiss(notification) {
    if (notification.classList.contains(this.closedClass)) return; // already dismissing
    this.clearTimers(notification);
    notification.classList.add(this.transparentClass, this.closedClass);
    // Remove once the fade-out has run. Reading the computed duration means reduced-motion (0s)
    // removes immediately, and we don't depend on a `transitionend` (which doesn't fire for a
    // 0s transition, nor when the notification was dismissed before it finished fading in).
    this.track(
      notification,
      setTimeout(() => this.remove(notification), this.fadeOutMs(notification))
    );
  }

  /**
   * Dismisses a notification when it's clicked.
   * @param {Event} event Click event.
   */
  close(event) {
    this.dismiss(event.currentTarget);
  }

  /**
   * Removes a notification from the DOM and drops its tracked timers.
   * @param {HTMLElement} notification
   */
  remove(notification) {
    this.clearTimers(notification);
    notification.remove();
  }

  showSuccessIcon(status) {
    return status === 'success';
  }

  /**
   * Records a pending timer against a notification so it can be cancelled later.
   * @param {HTMLElement} notification
   * @param {number} timerId
   */
  track(notification, timerId) {
    const timers = this.timers.get(notification) ?? [];
    timers.push(timerId);
    this.timers.set(notification, timers);
  }

  /**
   * Cancels and forgets every pending timer for a notification.
   * @param {HTMLElement} notification
   */
  clearTimers(notification) {
    const timers = this.timers.get(notification);
    if (timers) {
      timers.forEach((id) => clearTimeout(id));
      this.timers.delete(notification);
    }
  }

  /**
   * The notification's opacity transition duration, in milliseconds (0 under reduced-motion).
   * @param {HTMLElement} notification
   * @returns {number}
   */
  fadeOutMs(notification) {
    const seconds = parseFloat(
      getComputedStyle(notification).transitionDuration
    );
    return Number.isFinite(seconds) ? seconds * 1000 : 0;
  }
}
