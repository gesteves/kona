import { Controller } from '@hotwired/stimulus';

/**
 * The selectors for the page content behind the open menu. The header is absent, on purpose: it
 * contains the menu and its button, thus an inert header would leave the user with no way out.
 */
const BACKGROUND_SELECTORS = ['#main-content', '.footer'];

/** Opens and closes the navigation menu, and keeps the ARIA state of its button correct. */
export default class extends Controller {
  static classes = ['open'];
  static targets = ['button', 'menu'];
  static values = {
    openAriaLabel: { type: String, default: 'Open menu' },
    closeAriaLabel: { type: String, default: 'Close menu' },
  };

  /**
   * Opens the navigation menu, or closes it.
   * @param {Event} event The event that started this action.
   */
  toggleNav(event) {
    event.preventDefault();
    this.isNavOpen() ? this.closeNav() : this.openNav();
  }

  /** Opens the navigation menu. */
  openNav() {
    // The open menu makes <body> fixed, which makes the scroll height of the document zero. Keep
    // the position of the reader, thus a close puts them back and not at the top.
    this.scrollY = window.scrollY;
    document.body.classList.add(this.openClass);
    document.body.style.top = `-${this.scrollY}px`;
    this.setBackgroundInert(true);
    this.updateButtonAttributes();
    this.focusMenu();
  }

  /**
   * Moves the focus into the menu on an open, and back to the button on a close.
   *
   * ⚠️ This is necessary, and not an improvement: the list is before its own button in the DOM,
   * and each element after the button is inert while the menu is open. Thus without this code, Tab
   * from the button goes nowhere, and the only way into the menu is shift-Tab.
   */
  focusMenu() {
    if (!this.hasMenuTarget) return;
    this.menuTarget.querySelector('a, button')?.focus();
  }

  /**
   * Closes the navigation menu. turbo:before-cache and search:close also call it, thus it runs
   * when the menu is open and when it is closed. Only the scroll position has a condition.
   */
  closeNav() {
    const wasOpen = this.isNavOpen();
    document.body.classList.remove(this.openClass);
    this.setBackgroundInert(false);
    this.updateButtonAttributes();

    if (!wasOpen) return;
    document.body.style.top = '';
    window.scrollTo(0, this.scrollY ?? 0);

    // Do this only while the focus is in the nav. This code also runs on turbo:before-cache and
    // on search:close, where a move of the focus back to the menu button would be incorrect.
    if (this.hasButtonTarget && this.element.contains(document.activeElement)) {
      this.buttonTarget.focus();
    }
  }

  /** Removes each inert attribute and the fixed body when the element goes away. */
  disconnect() {
    document.body.classList.remove(this.openClass);
    document.body.style.top = '';
    this.setBackgroundInert(false);
  }

  /**
   * Removes the page behind the menu from the tab order and from the accessibility tree. The menu
   * covers the full viewport, thus without this the reader can use Tab to go through it into
   * content that they cannot see.
   * @param {Boolean} inert True to make the background inert.
   */
  setBackgroundInert(inert) {
    BACKGROUND_SELECTORS.forEach((selector) => {
      const element = document.querySelector(selector);
      if (element) element.inert = inert;
    });
  }

  /** Changes the ARIA attributes of the button to agree with the state of the nav. */
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
