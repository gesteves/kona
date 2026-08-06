import { initSearchTracking } from '../lib/analytics';
import { loadPagefind, preloadPagefindWhenIdle } from '../lib/pagefind';
import { Controller } from '@hotwired/stimulus';

/** Loads the Pagefind component UI and opens its search modal. */
export default class extends Controller {
  connect() {
    preloadPagefindWhenIdle();
  }

  /** Hover/focus is the earliest signal someone is heading for search. */
  preload() {
    loadPagefind();
  }

  /**
   * Opens the search modal, awaiting the component UI in case the preloads haven't finished.
   * @param {Event} event - The event that triggered the open.
   */
  async open(event) {
    event.preventDefault();
    await loadPagefind();
    document.querySelector('pagefind-modal')?.open?.();
    initSearchTracking();
    // On mobile the Search item sits inside the open hamburger menu; close it so dismissing
    // search returns straight to the page. After the await on purpose: if the modal isn't
    // ready, leaving the menu up beats closing it onto a bare page.
    this.dispatch('close', { target: document });
  }
}
