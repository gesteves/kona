import { initSearchTracking } from '../lib/analytics';
import { loadPagefind, preloadPagefindWhenIdle } from '../lib/pagefind';
import { Controller } from '@hotwired/stimulus';

export default class extends Controller {
  connect() {
    // Idle-load the component UI once the page is done loading, so a click almost never
    // has to wait on the network. Idempotent — every Search trigger calls it.
    preloadPagefindWhenIdle();
  }

  // Hover/focus is the earliest reliable signal that someone is heading for search.
  // Covers the click that lands before the idle callback has run.
  preload() {
    loadPagefind();
  }

  async open(event) {
    event.preventDefault();
    // `<pagefind-modal>` is inert until /pagefind/pagefind-component-ui.js defines it
    // (built site only — see lib/pagefind.js). Usually already resolved by the idle
    // preload; awaiting covers the case where it isn't.
    await loadPagefind();
    document.querySelector('pagefind-modal')?.open?.();
    // Idempotent; subscribes to the modal's search instance once (built site only).
    initSearchTracking();
    // On mobile the Search item lives inside the open hamburger menu. Tell the nav to
    // close now (hidden behind the full-screen modal) so dismissing search returns
    // straight to the page. The nav listens for `search:close` via `data-action`;
    // a no-op on desktop / when already closed. Deliberately after the await: if the
    // modal isn't ready yet, leaving the menu up beats closing it onto a bare page.
    this.dispatch('close', { target: document });
  }
}
