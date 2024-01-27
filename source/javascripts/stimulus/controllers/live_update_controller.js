import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static values = {
    url: String
  };

  /**
   * Updates content when the page becomes visible.
   */
  handleVisibilityChange() {
    if (document.visibilityState === "visible") {
      this.fetchAndUpdateContent();
    }
  }

  /**
   * Fetches data from a URL and updates the content of the element.
   * @async
   * @returns {Promise<void>} A promise that resolves when the content is updated.
   */
  async fetchAndUpdateContent() {
    if (this.hasUrlValue) {
      try {
        let response = await fetch(this.urlValue);
        let data = await response.text();
        
        const newElement = document.createElement('div');
        newElement.innerHTML = data.trim();
  
        this.element.replaceWith(newElement.firstChild);
      } catch (error) {
        console.error('Error fetching content:', error);
      }
    }
  }
}
