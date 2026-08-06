import { Controller } from '@hotwired/stimulus';

/** Clears an image's placeholder background once it has loaded or failed. */
export default class extends Controller {
  connect() {
    // The `load`/`error` actions cover images that finish after connect; this covers ones that
    // already finished, which won't fire those events again.
    if (this.element.complete) {
      this.removePlaceholder();
    }
  }

  /** Removes the placeholder background. */
  removePlaceholder() {
    this.element.classList.remove('placeholder');
  }
}
