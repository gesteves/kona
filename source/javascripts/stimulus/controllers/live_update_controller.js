import { Controller } from '@hotwired/stimulus';
import { replaceElement } from '../lib/utils';

/**
 * Controller class for managing dynamic content updates.
 */
export default class extends Controller {
  static values = {
    url: String,
  };

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
        let data = await response.text();

        if (data.trim().length > 0) {
          replaceElement(data.trim(), this.element);
        }
      } catch (error) {
        console.error('Error fetching content:', error);
      }
    }
  }
}
