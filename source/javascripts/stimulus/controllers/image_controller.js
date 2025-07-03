import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["img"]

  connect() {
    // Handle images that might already be loaded when the controller connects
    this.imgTargets.forEach(img => {
      if (img.complete && img.naturalHeight !== 0) {
        this.removePlaceholder(img)
      } else {
        // Set up event listeners for images that aren't loaded yet
        img.addEventListener('load', () => this.removePlaceholder(img))
        img.addEventListener('error', () => this.removePlaceholder(img))
      }
    })
  }

  removePlaceholder(img) {
    img.classList.remove('placeholder')
  }
}