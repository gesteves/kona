import { Controller } from "@hotwired/stimulus";

/**
 * Empties the toast stack before Turbo caches the page.
 *
 * ⚠️ The countdown of a `<wa-toast-item>` stops when Turbo disconnects the DOM, and it never starts
 * again. Thus a message in the snapshot appears again, and it does not go away, at the next
 * restoration visit. The flash controller and the dialog controller exist for the same problem.
 */
export default class extends Controller {
  connect() {
    this.clear = () => this.element.replaceChildren();
    document.addEventListener("turbo:before-cache", this.clear);
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.clear);
  }
}
