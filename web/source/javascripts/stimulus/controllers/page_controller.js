import { trackPageView } from '../lib/analytics';
import { Controller } from '@hotwired/stimulus';

/** Page-level Turbo lifecycle hooks. */
export default class extends Controller {
  /** Tracks a page view. Wired to `turbo:load`. */
  load() {
    trackPageView();
  }

  /**
   * Empties the toast stack before Turbo caches the page. Wired to `turbo:before-cache`.
   * A `<wa-toast-item>`'s countdown dies when Turbo disconnects the DOM and never restarts, so
   * a toast carried into a snapshot resurfaces frozen the next time the stack opens.
   */
  clearNotifications() {
    document.getElementById('notifications')?.replaceChildren();
  }
}
