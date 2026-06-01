import { Controller } from '@hotwired/stimulus';

export default class extends Controller {
  connect() {
    // The `load`/`error` actions cover images that finish after connect; this handles ones that
    // already finished (loaded or errored) before the controller attached, which wouldn't fire
    // those events again.
    if (this.element.complete) {
      this.removePlaceholder();
    }
  }

  /**
   * Removes the placeholder background once the image has loaded (or failed to).
   */
  removePlaceholder() {
    this.element.classList.remove('placeholder');
  }
}
