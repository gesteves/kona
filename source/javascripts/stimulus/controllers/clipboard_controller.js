import { Controller } from "@hotwired/stimulus";
import ClipboardJS from 'clipboard';

export default class extends Controller {
  static classes = ['hidden']
  static targets = ['button', 'link', 'check'];

  connect() {
    this.clipboard = new ClipboardJS(this.buttonTarget, {
      text: () => this.getPermalink()
    });

    this.clipboard.on('success', () => this.successfulCopy());
    this.clipboard.on('error', () => this.unsuccessfulCopy());
  }

  disconnect() {
    this.clipboard.destroy();
  }

  /**
   * Convenience method to stop the button from doing its thing.
   * @param  {Event} event Click event from the button.
   */
  preventDefault (event) {
    event.preventDefault();
  }

  /**
   * Get the permalink from the button's href attribute.
   * Handles both relative and absolute URLs, as well as anchor links.
   * @return {String} Permalink URL.
   */
  getPermalink() {
    const href = this.buttonTarget.getAttribute('href');
    if (href.startsWith('#')) {
      return window.location.origin + window.location.pathname + href;
    } else if (href.startsWith('/')) {
      return window.location.origin + href;
    } else {
      return href;
    }
  }

  /**
   * Handles successful copy event.
   * Show the check icon and hide the link icon.
   * Revert back after a few seconds.
   */
  successfulCopy() {
    // Hide the link icon and show the circle-check icon
    this.linkTarget.classList.add(this.hiddenClass);
    this.checkTarget.classList.remove(this.hiddenClass);

    // Revert back after 5 seconds
    setTimeout(() => {
      this.linkTarget.classList.remove(this.hiddenClass);
      this.checkTarget.classList.add(this.hiddenClass);
    }, 2000);
  }

  /**
   * Show the link in an alert if copying fails.
   */
  unsuccessfulCopy() {
    const href = this.buttonTarget.getAttribute('href');
    alert(href);
  }
}
