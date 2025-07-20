import { Controller } from '@hotwired/stimulus';

/**
 * Controller for going back to the top of the page.
 */
export default class extends Controller {
  /**
   * Scrolls to the top of the page when the button is clicked.
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
