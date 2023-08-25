import { trackPageView } from '../lib/analytics';
import { Controller } from "stimulus";

export default class extends Controller {
  connect() {
    trackPageView();
    this.cleanUpUrl();
  }

  cleanUpUrl() {
    if (window.location.search) {
      const cleanURL = window.location.origin + window.location.pathname;
      window.history.replaceState({}, document.title, cleanURL);
    }
  }
}
