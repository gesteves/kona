import { Controller } from '@hotwired/stimulus';

/** Removes the placeholder background of an image after it loads or fails. */
export default class extends Controller {
  connect() {
    // The `load` and `error` actions cover an image that completes after the connect. This code
    // covers an image that already completed, which sends neither event again.
    if (this.element.complete) {
      this.removePlaceholder();
    }
  }

  /** Removes the placeholder background. */
  removePlaceholder() {
    this.element.classList.remove('placeholder');
  }
}
