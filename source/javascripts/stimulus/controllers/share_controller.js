import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static classes = ["hidden"];
  static values = {
    popupWidth: Number,
    popupHeight: Number,
    isNative: Boolean,
    text: String,
    url: String
  };

  connect() {
    if (navigator.share && this.isNativeValue) {
      this.element.classList.remove(this.hiddenClass);
    }
  }

  getShareUrl() {
    return this.urlValue || document.querySelector('link[rel="canonical"]')?.href || window.location.href
  }

  getShareText() {
    return this.textValue || document.querySelector('meta[property="og:title"]')?.content || document.title;
  }

  openShareSheet(event) {
    event.preventDefault();

    navigator.share({
      title: this.getShareText(),
      url: this.getShareUrl()
    }).catch(() => {
      // Handle potential error silently
    });
  }

  openPopup(event) {
    event.preventDefault();
    const linkURL = this.element.href;
    
    const width = this.popupWidthValue || 400;
    const height = this.popupHeightValue || 300;

    window.open(linkURL, 'share', `width=${width},height=${height},scrollbars=yes`);
  }

  shareOnMastodon(event) {
    event.preventDefault();
  
    const rawDomain = prompt("What’s your Mastodon instance?", "mastodon.social");
  
    if (!rawDomain) {
      return;
    }
  
    const domain = this.extractDomain(rawDomain);
    
    if (!domain) {
      alert("That doesn’t look quite right, please try again.");
      return;
    }
  
    const mastodonShareUrl = `https://${domain}/share?text=${encodeURIComponent(this.getShareText())}`;

    window.location.href = mastodonShareUrl;
  }
  
  extractDomain(rawInput) {
    try {
      const input = rawInput.startsWith('http') ? rawInput : `https://${rawInput}`;
      const url = new URL(input);
      return url.hostname;
    } catch (error) {
      return null;
    }
  }
}
