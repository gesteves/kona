import { Controller } from "@hotwired/stimulus";

/**
 * Closes a dialog before Turbo caches the page.
 *
 * ⚠️ Turbo snapshots the DOM as it stands, so opening a confirmation dialog, navigating away, and
 * pressing Back restores the page with the dialog still open — and a restoration visit never
 * re-renders, so nothing would close it. Same trap the flash controller exists for.
 */
export default class extends Controller {
  connect() {
    this.close = () => this.element.removeAttribute("open");
    document.addEventListener("turbo:before-cache", this.close);
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.close);
  }
}
