import { trackPageView } from '../lib/analytics';
import { Controller } from '@hotwired/stimulus';

/** The Turbo lifecycle methods of the page. */
export default class extends Controller {
  /** Records a page view. `turbo:load` calls it. */
  load() {
    trackPageView();
  }

  /**
   * Removes each toast from the stack before Turbo caches the page. `turbo:before-cache` calls it.
   * The countdown of a `<wa-toast-item>` stops when Turbo disconnects the DOM, and it never starts
   * again. Thus a toast in a snapshot appears again, and it does not move, the next time that the
   * stack opens.
   */
  clearNotifications() {
    document.getElementById('notifications')?.replaceChildren();
  }
}
