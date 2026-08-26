import { initSearchTracking } from '../lib/analytics';
import { loadPagefind, preloadPagefindWhenIdle } from '../lib/pagefind';
import { Controller } from '@hotwired/stimulus';

// The menu button of the nav. It is the focus target when the trigger of the search is in the menu,
// which closeNav made invisible. Refer to returnFocus.
const NAV_BUTTON_ID = 'nav-button';

/** Loads the Pagefind component UI and opens its search modal. */
export default class extends Controller {
  connect() {
    preloadPagefindWhenIdle();
  }

  /** A pointer or a focus on the button is the first sign that a person wants to search. */
  preload() {
    loadPagefind();
  }

  /**
   * Opens the search modal. It waits for the component UI, because an earlier load can be in
   * progress.
   * @param {Event} event - The event that started the open.
   */
  async open(event) {
    event.preventDefault();
    await loadPagefind();
    const modal = document.querySelector('pagefind-modal');
    if (!modal?.open) return;

    modal.open();
    initSearchTracking();
    this.restoreFocusOnClose(modal);
    // On a mobile screen, the Search item is in the open menu. Close that menu, thus a close of the
    // search goes directly to the page. This is after the wait, on purpose: if the modal is not
    // ready, an open menu is better than a close onto an empty page.
    this.dispatch('close', { target: document });
  }

  /**
   * Moves the focus back when the modal closes.
   *
   * ⚠️ This is necessary, and the <dialog> does not do it. Pagefind opens with showModal(), thus
   * the browser remembers the element that had the focus and gives it back on a close. On a mobile
   * screen that element is the Search item INSIDE the menu, and the `close` above then makes the
   * menu `visibility: hidden`. Such an element cannot take the focus, thus the browser drops the
   * focus on the body and the user loses their place.
   * @param {Element} modal - The pagefind-modal element.
   */
  restoreFocusOnClose(modal) {
    // Pagefind makes the dialog in the light DOM, thus a plain query finds it.
    const dialog = modal.querySelector('dialog');
    dialog?.addEventListener('close', () => this.returnFocus(), { once: true });
  }

  /**
   * Gives the focus to the trigger, or to the menu button when the trigger is not visible. It tries
   * the trigger and then reads document.activeElement, thus it needs no test of the CSS and it is
   * correct for each reason that an element cannot take the focus.
   */
  returnFocus() {
    this.element.focus();
    if (document.activeElement === this.element) return;

    document.getElementById(NAV_BUTTON_ID)?.focus();
  }
}
