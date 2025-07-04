import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    // Handle images that might already be loaded when the controller connects
    if (this.element.complete && this.element.naturalHeight !== 0) {
      this.removePlaceholder()
    }
  }

  /**
   * Removes the placeholder background when the image loads.
   */
  removePlaceholder() {
    this.element.classList.remove('placeholder')
  }
}
