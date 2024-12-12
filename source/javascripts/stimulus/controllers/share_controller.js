import { Controller } from "@hotwired/stimulus";
import { trackEvent } from '../lib/analytics';

/**
 * Controller for managing social sharing functionality.
 */
export default class extends Controller {
  static classes = ["hidden"];
  static values = {
    popupWidth: Number,
    popupHeight: Number,
    isNative: Boolean,
    text: String,
    url: String
  };

  /**
   * If the native share API is available and the `isNativeValue` is true,
   * the element's hidden class is removed.
   */
  connect() {
    if (navigator.share && this.isNativeValue) {
      this.element.classList.remove(this.hiddenClass);
    }
  }

  /**
   * Gets the URL to share. It returns the URL from the `urlValue` if available,
   * otherwise, it checks for the canonical URL in the document or uses the current window location URL.
   * @returns {string} The URL to share.
   */
  getShareUrl() {
    return this.urlValue || document.querySelector('link[rel="canonical"]')?.href || window.location.href
  }

  /**
   * Gets the text to share. It returns the text from the `textValue` if available,
   * otherwise, it checks for the Open Graph title in the document's meta tags or uses the document title.
   * @returns {string} The text to share.
   */
  getShareText() {
    return this.textValue || document.querySelector('meta[property="og:title"]')?.content || document.title;
  }

  /**
   * Opens the native share sheet to share the current page's title and URL. It uses the `navigator.share` API
   * and handles any potential errors silently.
   * @param {Event} event - The event that triggered the share action (e.g., a click event).
   */
  openShareSheet(event) {
    event.preventDefault();
    trackEvent('Open Share', { url: this.getShareUrl() });

    navigator.share({
      title: this.getShareText(),
      url: this.getShareUrl()
    }).catch(() => {
      // Handle potential error silently
    });
  }

  /**
   * Opens a popup window for sharing the linked URL.
   * @param {Event} event - The event that triggered the popup window (e.g., a click event).
   */
  openPopup(event) {
    event.preventDefault();
    const linkURL = this.element.href;
    
    const width = this.popupWidthValue || 400;
    const height = this.popupHeightValue || 300;

    window.open(linkURL, 'share', `width=${width},height=${height},scrollbars=yes`);
  }
}
