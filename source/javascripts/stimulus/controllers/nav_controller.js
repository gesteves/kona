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

  /**
   * When Turbo loads a page from its cache, sometimes it renders it with the nav open,
   * since it was cached that way.
   * So, before rendering a Turbo page, remove the open class from the new body.
   * @param {Event} event  The turbo:before-render event that contains the new body.
   */
  closeNavInNewBody(event) {
    event.preventDefault();
    event.detail.newBody.classList.remove(this.openClass);
    event.detail.resume();
  }
}
