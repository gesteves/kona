import { Controller } from "@hotwired/stimulus";

/**
 * Removes a flash message before Turbo caches the page.
 *
 * ⚠️ Without this the flash is baked into the cached snapshot, so navigating away and pressing
 * Back re-displays a "Whoop disconnected." banner for an action that already happened — and a
 * restoration visit never re-renders, so nothing would clear it.
 */
export default class extends Controller {
  connect() {
    this.remove = () => this.element.remove();
    document.addEventListener("turbo:before-cache", this.remove);
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.remove);
  }

  /** Dismisses the message now, from the callout's own close button. */
  dismiss() {
    this.element.remove();
  }
}
