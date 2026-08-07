import { Controller } from '@hotwired/stimulus';

/**
 * Selectors for the page content behind the open menu. The header is deliberately absent — it
 * contains the menu and its trigger, so making it inert would trap the user with no way out.
 */
const BACKGROUND_SELECTORS = ['#main-content', '.footer'];

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
    this.isNavOpen() ? this.closeNav() : this.openNav();
  }

  /** Opens the navigation menu. */
  openNav() {
    // The open menu fixes <body>, which collapses the document's scroll height. Remember where
    // the reader was so closing can put them back instead of dumping them at the top.
    this.scrollY = window.scrollY;
    document.body.classList.add(this.openClass);
    document.body.style.top = `-${this.scrollY}px`;
    this.setBackgroundInert(true);
    this.updateButtonAttributes();
  }

  /**
   * Closes the navigation menu. Also bound to turbo:before-cache and search:close, so it runs
   * whether or not the menu was open — only the scroll restore is conditional.
   */
  closeNav() {
    const wasOpen = this.isNavOpen();
    document.body.classList.remove(this.openClass);
    this.setBackgroundInert(false);
    this.updateButtonAttributes();

    if (!wasOpen) return;
    document.body.style.top = '';
    window.scrollTo(0, this.scrollY ?? 0);
  }

  /** Leaves no inert attributes or fixed body behind when the element goes away. */
  disconnect() {
    document.body.classList.remove(this.openClass);
    document.body.style.top = '';
    this.setBackgroundInert(false);
  }

  /**
   * Hides the page behind the menu from the tab order and the accessibility tree. The menu is a
   * full-viewport overlay, so without this the reader can tab straight through it into content
   * they can't see.
   * @param {Boolean} inert Whether the background should be inert.
   */
  setBackgroundInert(inert) {
    BACKGROUND_SELECTORS.forEach((selector) => {
      const element = document.querySelector(selector);
      if (element) element.inert = inert;
    });
  }

  /** Updates the button's ARIA attributes to match the nav's state. */
  updateButtonAttributes() {
    if (!this.hasButtonTarget) return;
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
