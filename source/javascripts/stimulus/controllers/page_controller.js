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
   * Closes the navigation menu when a link is clicked.
   * This is called on every `turbo:click` event.
   * @see https://turbo.hotwired.dev/reference/events
   */
  click() {
    document.body.className = '';
  }
}
