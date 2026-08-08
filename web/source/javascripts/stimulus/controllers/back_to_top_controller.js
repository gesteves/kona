import { Controller } from '@hotwired/stimulus';

/** Scrolls the page back to the top, honoring prefers-reduced-motion. */
export default class extends Controller {
  /**
   * @param {Event} event The click event that triggered the action.
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
   * Moves focus to the element the link points at.
   *
   * ⚠️ preventDefault above suppresses the hash navigation that would have done this, so without
   * it a keyboard user is scrolled to the top with focus left behind in the footer. tabindex=-1
   * makes a non-interactive target focusable without adding it to the tab order.
   * @param {HTMLElement} link The clicked link.
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
