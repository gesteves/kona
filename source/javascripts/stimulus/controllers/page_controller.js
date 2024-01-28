import { trackPageView } from '../lib/analytics';
import { isProduction } from '../lib/context';
import { Controller } from "@hotwired/stimulus";

/**
 * Controller class for managing page views.
 */
export default class extends Controller {
  /**
   * Tracks a page view when the page loads in production (to prevent bogus page views on dev & branch previews).
   * This is called on every `turbo:load` event.
   * @see https://turbo.hotwired.dev/reference/events
   */
  load() {
    if (isProduction()) {
      trackPageView();
    }
  }
}
