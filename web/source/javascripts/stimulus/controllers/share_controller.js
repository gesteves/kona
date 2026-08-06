import { Controller } from '@hotwired/stimulus';
import { trackEvent, trackEventThen } from '../lib/analytics';
import { canonicalUrl } from '../lib/utils';

/** Handles social sharing: the native share sheet, popup share windows, and share tracking. */
export default class extends Controller {
  static classes = ['hidden'];
  static values = {
    popupWidth: Number,
    popupHeight: Number,
    isNative: Boolean,
    text: String,
    url: String,
    via: String,
  };

  /** Reveals the element when it's the native-share trigger and the API is available. */
  connect() {
    if (navigator.share && this.isNativeValue) {
      this.element.classList.remove(this.hiddenClass);
    }
  }

  /**
   * @returns {string} `urlValue`, falling back to the document's canonical URL.
   */
  getShareUrl() {
    return this.urlValue || canonicalUrl();
  }

  /**
   * @returns {string} `textValue`, falling back to the document's og:title or title.
   */
  getShareText() {
    return (
      this.textValue ||
      document.querySelector('meta[property="og:title"]')?.content ||
      document.title
    );
  }

  /**
   * Opens the native share sheet for the page's title and URL.
   * @param {Event} event - The event that triggered the share action.
   */
  openShareSheet(event) {
    event.preventDefault();
    trackEvent('Share', { url: this.getShareUrl(), via: 'Native' });

    navigator
      .share({
        title: this.getShareText(),
        url: this.getShareUrl(),
      })
      .catch((error) => {
        if (error.name !== 'AbortError') {
          console.error('Share failed:', error);
        }
      });
  }

  /**
   * Opens a popup window for sharing the linked URL.
   * @param {Event} event - The event that triggered the popup window (e.g., a click event).
   */
  openPopup(event) {
    event.preventDefault();
    const linkURL = this.element.href;

    trackEvent('Share', { url: this.getShareUrl(), via: this.viaValue });

    const width = this.popupWidthValue || 400;
    const height = this.popupHeightValue || 300;

    // `noopener` so the popup can't reach back to `window.opener` (reverse tabnabbing).
    window.open(
      linkURL,
      'share',
      `width=${width},height=${height},scrollbars=yes,noopener`
    );
  }

  /**
   * Tracks a share link, then follows it. mailto:/sms: navigate the current window, so the
   * event has to be sent first; HTTP(S) links open in a new tab and can't interrupt it.
   * @param {Event} event - The event that triggered the share action.
   */
  trackShare(event) {
    event.preventDefault();
    const linkURL = this.element.href;
    const props = { url: this.getShareUrl(), via: this.viaValue };

    if (linkURL.startsWith('mailto:') || linkURL.startsWith('sms:')) {
      trackEventThen('Share', props, () => {
        window.location.href = linkURL;
      });
    } else {
      trackEvent('Share', props);
      window.open(linkURL, '_blank', 'noopener,noreferrer');
    }
  }
}
