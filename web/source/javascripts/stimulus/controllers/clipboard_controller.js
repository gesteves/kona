import { Controller } from '@hotwired/stimulus';
import { absoluteUrl, sendNotification } from '../lib/utils';
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
    if (!navigator.clipboard) return this.unsuccessfulCopy();
    const permalink = this.getPermalink();
    navigator.clipboard
      .writeText(permalink)
      .then(() => this.successfulCopy(permalink))
      .catch(() => this.unsuccessfulCopy());
  }

  /**
   * @return {String} The button's href resolved to an absolute permalink.
   */
  getPermalink() {
    return absoluteUrl(this.element.getAttribute('href'));
  }

  /**
   * Swaps the link icon for a check for two seconds, toasts, and tracks the copy.
   * @param {String} permalink The URL that was copied.
   */
  successfulCopy(permalink) {
    if (this.hasLinkTarget && this.hasCheckTarget) {
      this.linkTarget.classList.add(this.hiddenClass);
      this.checkTarget.classList.remove(this.hiddenClass);
      this.revertTimer = setTimeout(() => {
        this.linkTarget.classList.remove(this.hiddenClass);
        this.checkTarget.classList.add(this.hiddenClass);
      }, 2000);
    }

    sendNotification(this.successMessageValue);
    trackEvent('Copy to Clipboard', { url: permalink });
  }

  /** Notifies the reader that copying failed. */
  unsuccessfulCopy() {
    sendNotification('Failed to copy link to clipboard.', 'error');
  }
}
