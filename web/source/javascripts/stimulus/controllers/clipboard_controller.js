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

  /**
   * Stops the revert timer and puts the link icon back. ⚠️ Turbo makes its snapshot before the
   * disconnect, thus without the revert a copy that is less than two seconds old comes back from
   * the cache with a check that stays for all time.
   */
  disconnect() {
    clearTimeout(this.revertTimer);
    if (this.hasLinkTarget && this.hasCheckTarget) {
      this.linkTarget.classList.remove(this.hiddenClass);
      this.checkTarget.classList.add(this.hiddenClass);
    }
  }

  /**
   * Copies the permalink to the clipboard with the native Clipboard API, and stops the navigation
   * of the link. It runs in the click, thus the browser permits writeText.
   * @param  {Event} event The click event from the button.
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
   * @return {String} The href of the button, as an absolute permalink.
   */
  getPermalink() {
    return absoluteUrl(this.element.getAttribute('href'));
  }

  /**
   * Puts a check in place of the link icon for two seconds, shows a toast, and records the copy.
   * @param {String} permalink The URL that the code copied.
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

  /** Tells the reader that the copy failed. */
  unsuccessfulCopy() {
    sendNotification('Failed to copy link to clipboard.', 'error');
  }
}
