import { Controller } from '@hotwired/stimulus';
import { trackEvent } from '../lib/analytics';

/**
 * Controller for toggling the navigation menu.
 */
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
    trackEvent('Nav', { state: this.isNavOpen() ? 'Open' : 'Closed' });
  }

  /**
   * Closes the navigation menu.
   */
  closeNav() {
    document.body.classList.remove(this.openClass);
    this.updateButtonAttributes();
  }

  /**
   * Updates the button's ARIA attributes to match the nav's state.
   */
  updateButtonAttributes() {
    this.buttonTarget.setAttribute('aria-expanded', this.isNavOpen());
    this.buttonTarget.setAttribute(
      'aria-label',
      this.isNavOpen() ? this.closeAriaLabelValue : this.openAriaLabelValue
    );
  }

  /**
   * Checks if the navigation menu is open.
   * @returns {Boolean} True if the navigation menu is open, false otherwise.
   */
  isNavOpen() {
    return document.body.classList.contains(this.openClass);
  }
}
