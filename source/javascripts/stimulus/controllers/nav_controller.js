import { Controller } from "@hotwired/stimulus";

/**
 * Controller for toggling the navigation menu.
 */
export default class extends Controller {
  static classes = ["open"];
  static targets = ["button"];

  /**
   * Toggles the navigation menu.
   * @param {Event} event The event that triggered the toggle.
   */
  toggleNav(event) {
    event.preventDefault();
    document.body.classList.toggle(this.openClass);
    this.buttonTarget.setAttribute("aria-expanded", document.body.classList.contains(this.openClass));
    this.buttonTarget.setAttribute("aria-label", document.body.classList.contains(this.openClass) ? "Close menu" : "Open menu");
  }
}
