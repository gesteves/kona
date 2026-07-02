import { Controller } from '@hotwired/stimulus';
import { sendNotification } from '../lib/utils';
import { trackEvent } from '../lib/analytics';

export default class extends Controller {
  static classes = ['hidden'];
  static targets = ['link', 'check'];
  static values = {
    successMessage: {
      type: String,
      default: 'The link has been copied to your clipboard.',
    },
  };

  disconnect() {
    clearTimeout(this.revertTimer);
  }

  /**
   * Copies the permalink to the clipboard via the native Clipboard API, stopping the link
   * from navigating. Runs inside the click gesture, so writeText is allowed.
   * @param  {Event} event Click event from the button.
   */
  copy(event) {
    event.preventDefault();
    const permalink = this.getPermalink();
    navigator.clipboard
      .writeText(permalink)
      .then(() => this.successfulCopy(permalink))
      .catch(() => this.unsuccessfulCopy());
  }

  /**
   * Get the permalink from the button's href attribute.
   * Handles both relative and absolute URLs, as well as anchor links.
   * @return {String} Permalink URL.
   */
  getPermalink() {
    const href = this.element.getAttribute('href');
    if (!href) {
      return window.location.href;
    } else if (href.startsWith('#')) {
      return window.location.origin + window.location.pathname + href;
    } else if (href.startsWith('//')) {
      return href;
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
   * @param {String} permalink The URL that was copied.
   */
  successfulCopy(permalink) {
    if (this.hasLinkTarget && this.hasCheckTarget) {
      // Hide the link icon and show the circle-check icon
      this.linkTarget.classList.add(this.hiddenClass);
      this.checkTarget.classList.remove(this.hiddenClass);
      // Revert back after 2 seconds
      this.revertTimer = setTimeout(() => {
        this.linkTarget.classList.remove(this.hiddenClass);
        this.checkTarget.classList.add(this.hiddenClass);
      }, 2000);
    }

    sendNotification(this.successMessageValue);
    trackEvent('Copy to Clipboard', { url: permalink });
  }

  /**
   * Show a notification if copying fails.
   */
  unsuccessfulCopy() {
    sendNotification('Failed to copy link to clipboard.', 'error');
  }
}
