import { Controller } from "@hotwired/stimulus";

/**
 * Closes a dialog before Turbo caches the page.
 *
 * ⚠️ Turbo makes its snapshot of the DOM as it is. Thus an open confirmation dialog, a navigation
 * away, and a press of Back give a page with that dialog still open. A restoration visit never
 * renders again, thus nothing would close it. The flash controller exists for the same problem.
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
