import { Controller } from '@hotwired/stimulus';
import { trackEvent, trackEventThen } from '../lib/analytics';
import { canonicalUrl } from '../lib/utils';

/** Does the social sharing: the native share sheet, the popup share windows, and the share
 * records. */
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

  /** Shows the element when it is the native-share button and the API is available. */
  connect() {
    if (navigator.share && this.isNativeValue) {
      this.element.classList.remove(this.hiddenClass);
    }
  }

  /**
   * @returns {string} `urlValue`, or the canonical URL of the document.
   */
  getShareUrl() {
    return this.urlValue || canonicalUrl();
  }

  /**
   * @returns {string} `textValue`, or the og:title of the document, or its title.
   */
  getShareText() {
    return (
      this.textValue ||
      document.querySelector('meta[property="og:title"]')?.content ||
      document.title
    );
  }

  /**
   * Opens the native share sheet with the title and the URL of the page.
   * @param {Event} event - The event that started the share action.
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
   * Opens a popup window to share the URL of the link.
   * @param {Event} event - The event that started the popup window, for example a click.
   */
  openPopup(event) {
    event.preventDefault();
    const linkURL = this.element.href;

    trackEvent('Share', { url: this.getShareUrl(), via: this.viaValue });

    const width = this.popupWidthValue || 400;
    const height = this.popupHeightValue || 300;

    // `noopener` stops the popup from a change to `window.opener`, which is reverse
    // tabnabbing.
    window.open(
      linkURL,
      'share',
      `width=${width},height=${height},scrollbars=yes,noopener`
    );
  }

  /**
   * Records a share link, then goes to it. A mailto: link and an sms: link navigate the current
   * window, thus the code must send the event first. An HTTP or HTTPS link opens in a new tab and
   * cannot stop the event.
   * @param {Event} event - The event that started the share action.
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
