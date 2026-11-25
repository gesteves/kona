import { Controller } from '@hotwired/stimulus';
import { trackEvent, trackEventThen } from '../lib/analytics';
import { canonicalUrl } from '../lib/utils';

/** Does the social sharing: the native share sheet, the popup windows, and the share records. */
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

  getShareUrl() {
    return this.urlValue || canonicalUrl();
  }

  getShareText() {
    return (
      this.textValue ||
      document.querySelector('meta[property="og:title"]')?.content ||
      document.title
    );
  }

  /** Opens the native share sheet with the title and the URL of the page. */
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

  /** Opens a popup window to share the URL of the link. */
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
   * Records a share link. A mailto: link and an sms: link navigate the current window, thus the
   * code stops the click and records the event first. An HTTP or HTTPS link has `target="_blank"`
   * in the markup, thus the browser opens it, and a popup blocker treats that navigation better
   * than a `window.open` from code.
   */
  trackShare(event) {
    const linkURL = this.element.href;
    const props = { url: this.getShareUrl(), via: this.viaValue };

    if (linkURL.startsWith('mailto:') || linkURL.startsWith('sms:')) {
      event.preventDefault();
      trackEventThen('Share', props, () => {
        window.location.href = linkURL;
      });
    } else {
      trackEvent('Share', props);
    }
  }
}
