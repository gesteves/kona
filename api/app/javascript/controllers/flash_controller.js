import { Controller } from "@hotwired/stimulus";

/**
 * Removes a flash message before Turbo caches the page.
 *
 * ⚠️ Without this code, the flash message is in the snapshot in the cache. Thus a navigation away
 * and then a press of Back shows a "Whoop disconnected." message for an action that already
 * occurred. A restoration visit never renders again, thus nothing would remove it.
 */
export default class extends Controller {
  connect() {
    this.remove = () => this.element.remove();
    document.addEventListener("turbo:before-cache", this.remove);
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.remove);
  }

  /** Removes the message now, from the close button of the callout. */
  dismiss() {
    this.element.remove();
  }
}
