import { trackPageView } from '../lib/analytics';
import { isProduction } from '../lib/context';
import { Controller } from "@hotwired/stimulus";

/**
 * Controller class for managing page views.
 */
export default class extends Controller {
  /**
   * Tracks a page view when the page loads in production.
   * This method is called automatically by Stimulus.
   */
  load() {
    if (isProduction()) {
      trackPageView();
    }
  }
}
