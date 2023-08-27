import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static values = {
    url: String
  };

  handleVisibilityChange() {
    if (document.visibilityState === "visible") {
      this.fetchAndUpdateContent();
    }
  }

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
