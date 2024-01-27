import { trackPageView } from '../lib/analytics';
import { isProduction } from '../lib/context';
import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  /**
   * Tracks a page view when the page loads in production.
   */
  load() {
    if (isProduction()) {
      trackPageView();
    }
  }
}
