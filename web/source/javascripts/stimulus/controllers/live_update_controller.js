import { Controller } from '@hotwired/stimulus';
import { replaceElement } from '../lib/utils';

/**
 * Controller class for managing dynamic content updates.
 */
export default class extends Controller {
  static values = {
    url: String,
    fetchOnConnect: Boolean,
  };

  /**
   * Fetches content on connect when opted in (e.g. for markup served by an external API
   * rather than server-rendered into the page).
   */
  connect() {
    if (this.fetchOnConnectValue) {
      this.fetchAndUpdateContent();
    }
  }

  /**
   * Updates content when the page becomes visible.
   */
  handleVisibilityChange() {
    if (document.visibilityState === 'visible') {
      this.fetchAndUpdateContent();
    }
  }

  /**
   * Fetches data from a specified URL and updates the content of the associated element.
   * @async
   * @returns {Promise<void>} A promise that resolves when the content is updated, or if an error occurs.
   */
  async fetchAndUpdateContent() {
    if (this.hasUrlValue) {
      try {
        let response = await fetch(this.urlValue);
        // Non-2xx (proxy 502, origin error page) → remove the placeholder so it
        // collapses instead of leaving its loading skeleton stuck on the page.
        if (!response.ok) {
          this.element.remove();
          return;
        }
        let data = await response.text();

        if (data.trim().length > 0) {
          replaceElement(data.trim(), this.element);
        } else {
          // Empty body is a definitive "no data" answer (e.g. no current weather, no
          // race-day forecast). Remove the placeholder so it collapses instead of
          // leaving its loading skeleton on the page.
          this.element.remove();
        }
      } catch (error) {
        // Network failure (offline, DNS, abort) → same as above: collapse rather than
        // leave a stuck skeleton.
        console.error('Error fetching content:', error);
        this.element.remove();
      }
    }
  }
}
