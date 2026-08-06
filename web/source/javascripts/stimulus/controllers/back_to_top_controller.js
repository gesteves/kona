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
  }
}
