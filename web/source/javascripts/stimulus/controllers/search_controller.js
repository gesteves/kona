import { initSearchTracking } from '../lib/analytics';
import { Controller } from '@hotwired/stimulus';

export default class extends Controller {
  open(event) {
    event.preventDefault();
    // Defined only after /pagefind/pagefind-component-ui.js loads (built site only).
    document.querySelector('pagefind-modal')?.open?.();
    // Idempotent; subscribes to the modal's search instance once (built site only).
    initSearchTracking();
    // On mobile the Search item lives inside the open hamburger menu. Tell the nav to
    // close now (hidden behind the full-screen modal) so dismissing search returns
    // straight to the page. The nav listens for `search:close` via `data-action`;
    // a no-op on desktop / when already closed.
    this.dispatch('close', { target: document });
  }
}
