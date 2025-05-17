import { Controller } from "@hotwired/stimulus";

/**
 * Controller for toggling the navigation menu.
 */
export default class extends Controller {
  static classes = ["open"];

  /**
   * Toggles the navigation menu.
   * @param {Event} event The event that triggered the toggle.
   */
  toggleNav(event) {
    event.preventDefault();
    document.body.classList.toggle(this.openClass);
  }
}
