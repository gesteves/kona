import { Controller } from '@hotwired/stimulus';

/** Scrolls the page to the top. It obeys prefers-reduced-motion. */
export default class extends Controller {
  /**
   * @param {Event} event The click event that started the action.
   */
  go(event) {
    event.preventDefault();
    const rootElement = document.documentElement;

    const prefersReducedMotion = window.matchMedia(
      '(prefers-reduced-motion: reduce)'
    ).matches;

    rootElement.scrollTo({
      top: 0,
      behavior: prefersReducedMotion ? 'instant' : 'smooth',
    });

    this.focusTarget(event.currentTarget);
  }

  /**
   * Moves the focus to the element that the link points at.
   *
   * ⚠️ The preventDefault above stops the hash navigation that would move the focus. Thus without
   * this code, the page scrolls to the top for a keyboard user and the focus stays in the footer.
   * tabindex=-1 lets an element that is not interactive take the focus, and it does not put that
   * element in the tab order.
   * @param {HTMLElement} link The link that the user clicked.
   */
  focusTarget(link) {
    const hash = link?.getAttribute('href') ?? '';
    if (!hash.startsWith('#')) return;

    const destination = document.getElementById(hash.slice(1));
    if (!destination) return;

    if (!destination.hasAttribute('tabindex')) {
      destination.setAttribute('tabindex', '-1');
    }
    destination.focus({ preventScroll: true });
  }
}
