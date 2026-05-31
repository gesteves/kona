import { Controller } from '@hotwired/stimulus';

/**
 * Sets the element's text to the current year, so the footer copyright range stays correct without
 * a rebuild. The server renders the build-time year as the no-JS fallback.
 */
export default class extends Controller {
  connect() {
    this.element.textContent = new Date().getFullYear();
  }
}
