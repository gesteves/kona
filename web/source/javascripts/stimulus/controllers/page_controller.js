import { trackPageView } from '../lib/analytics';
import { Controller } from '@hotwired/stimulus';

/**
 * Controller class for managing page views.
 */
export default class extends Controller {
  /**
   * Tracks a page view when the page loads.
   * This is called on every `turbo:load` event.
   * @see https://turbo.hotwired.dev/reference/events
   */
  load() {
    trackPageView();
  }

  /**
   * Clears any in-flight toast notifications before Turbo caches the page.
   * Toasts are ephemeral per-page feedback: a `<wa-toast-item>`'s countdown
   * timer is killed when Turbo disconnects the DOM and never restarts, so a
   * toast carried into a cached snapshot becomes a frozen zombie that resurfaces
   * the next time the toast stack opens. Emptying the stack here keeps toasts
   * from leaking across navigations.
   * This is called on every `turbo:before-cache` event.
   * @see https://turbo.hotwired.dev/reference/events
   */
  clearNotifications() {
    document.getElementById('notifications')?.replaceChildren();
  }
}
