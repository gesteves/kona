import { initSearchTracking } from '../lib/analytics';
import { loadPagefind, preloadPagefindWhenIdle } from '../lib/pagefind';
import { Controller } from '@hotwired/stimulus';

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
    document.querySelector('pagefind-modal')?.open?.();
    initSearchTracking();
    // On a mobile screen, the Search item is in the open menu. Close that menu, thus a close of the
    // search goes directly to the page. This is after the wait, on purpose: if the modal is not
    // ready, an open menu is better than a close onto an empty page.
    this.dispatch('close', { target: document });
  }
}
