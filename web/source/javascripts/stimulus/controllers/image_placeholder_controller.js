import { Controller } from '@hotwired/stimulus';

/**
 * Removes the placeholder background of an image after it loads or fails. The `placeholder`
 * class is the class that draws that background.
 */
export default class extends Controller {
  static classes = ['placeholder'];

  connect() {
    // The `load` and `error` actions cover an image that completes after the connect. This code
    // covers an image that already completed, which sends neither event again.
    if (this.element.complete) {
      this.removePlaceholder();
    }
  }

  removePlaceholder() {
    // ⚠️ The plural form, on purpose: it gives an empty list for an image with no such attribute,
    // and the singular form raises. An api fragment from the edge cache can be an hour old.
    this.element.classList.remove(...this.placeholderClasses);
  }
}
