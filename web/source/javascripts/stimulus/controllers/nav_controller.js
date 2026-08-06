import { Controller } from '@hotwired/stimulus';

/** Toggles the navigation menu and keeps its trigger's ARIA state in sync. */
export default class extends Controller {
  static classes = ['open'];
  static targets = ['button'];
  static values = {
    openAriaLabel: { type: String, default: 'Open menu' },
    closeAriaLabel: { type: String, default: 'Close menu' },
  };

  /**
   * Toggles the navigation menu.
   * @param {Event} event The event that triggered the toggle.
   */
  toggleNav(event) {
    event.preventDefault();
    document.body.classList.toggle(this.openClass);
    this.updateButtonAttributes();
  }

  /** Closes the navigation menu. */
  closeNav() {
    document.body.classList.remove(this.openClass);
    this.updateButtonAttributes();
  }

  /** Updates the button's ARIA attributes to match the nav's state. */
  updateButtonAttributes() {
    this.buttonTarget.setAttribute('aria-expanded', this.isNavOpen());
    this.buttonTarget.setAttribute(
      'aria-label',
      this.isNavOpen() ? this.closeAriaLabelValue : this.openAriaLabelValue
    );
  }

  /**
   * @returns {Boolean} True if the navigation menu is open.
   */
  isNavOpen() {
    return document.body.classList.contains(this.openClass);
  }
}
