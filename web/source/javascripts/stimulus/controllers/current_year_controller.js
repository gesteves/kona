import { Controller } from '@hotwired/stimulus';

/**
 * Puts the current year in the text of the element, thus the range of copyright years in the footer
 * stays correct with no new build. The server renders the year of the build, for a browser with no
 * JavaScript.
 */
export default class extends Controller {
  connect() {
    this.element.textContent = new Date().getFullYear();
  }
}
