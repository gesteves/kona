import { trackPageView } from '../lib/analytics';
import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  cleanUpUrl() {
    if (window.location.search) {
      const cleanURL = window.location.origin + window.location.pathname;
      window.history.replaceState({}, document.title, cleanURL);
    }
  }

  handlePageLoad() {
    trackPageView();
    this.cleanUpUrl();
  }
}
