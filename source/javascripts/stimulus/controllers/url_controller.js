import { Controller } from "stimulus";

export default class extends Controller {
  connect() {
    this.trackPageView();
    this.cleanUpUrl();
  }

  trackPageView() {
    if (typeof plausible !== 'undefined') {
      plausible('pageview');
    }
  }

  cleanUpUrl() {
    if (window.location.search) {
      const cleanURL = window.location.origin + window.location.pathname;
      window.history.replaceState({}, document.title, cleanURL);
    }
  }
}
