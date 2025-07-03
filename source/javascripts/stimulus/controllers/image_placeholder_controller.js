import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    // Handle images that might already be loaded when the controller connects
    if (this.element.complete && this.element.naturalHeight !== 0) {
      this.removePlaceholder()
    }
  }

  // Action method to be called via data-action attributes
  removePlaceholder() {
    this.element.classList.remove('placeholder')
  }
}