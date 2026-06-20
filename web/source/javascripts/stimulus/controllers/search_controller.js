import { Controller } from '@hotwired/stimulus';

export default class extends Controller {
  open(event) {
    event.preventDefault();
    // Defined only after /pagefind/pagefind-component-ui.js loads (built site only).
    document.querySelector('pagefind-modal')?.open?.();
  }
}
