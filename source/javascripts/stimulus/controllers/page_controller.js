import { trackPageView } from '../lib/analytics';
import { Controller } from "@hotwired/stimulus";

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
   * Resets the body state before the page is cached.
   * @see https://turbo.hotwired.dev/reference/events
   */
  resetBody() {
    document.body.className = '';
  }
}
