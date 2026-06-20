import { initSearchTracking } from '../lib/analytics';
import { Controller } from '@hotwired/stimulus';

export default class extends Controller {
  open(event) {
    event.preventDefault();
    // Defined only after /pagefind/pagefind-component-ui.js loads (built site only).
    document.querySelector('pagefind-modal')?.open?.();
    // Idempotent; subscribes to the modal's search instance once (built site only).
    initSearchTracking();
    // On mobile the Search item lives inside the open hamburger menu. Close it now
    // (hidden behind the full-screen modal) so dismissing search returns straight to
    // the page instead of leaving the menu open. No-op on desktop / when already closed.
    this.closeNav();
  }

  /**
   * Closes the navigation menu via its controller, keeping the hamburger button's
   * ARIA state in sync. Resolves the nav controller through the Stimulus application
   * so no cross-element outlet wiring is needed on each "Search" trigger.
   */
  closeNav() {
    const nav = document.getElementById('nav');
    if (!nav) return;
    this.application
      .getControllerForElementAndIdentifier(nav, 'nav')
      ?.closeNav();
  }
}
