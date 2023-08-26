import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static classes = ["hidden"];
  static values = {
    popupWidth: Number,
    popupHeight: Number,
    isNative: Boolean
  };

  connect() {
    if (navigator.share && this.isNativeValue) {
      this.element.classList.remove(this.hiddenClass);
    }
  }

  getCanonicalOrFallbackUrl() {
    const canonicalLink = document.querySelector('link[rel="canonical"]');
    return canonicalLink ? canonicalLink.href : window.location.href;
  }

  openShareSheet(event) {
    event.preventDefault();
    const ogTitle = document.querySelector('meta[property="og:title"]')?.content || document.title;
    const url = this.getCanonicalOrFallbackUrl();
    const modifiedUrl = new URL(url);
    modifiedUrl.searchParams.append('ref', 'Share%20button');

    navigator.share({
      title: ogTitle,
      url: modifiedUrl.toString()
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

    const ogTitle = document.querySelector('meta[property="og:title"]')?.content || document.title;
    const url = this.getCanonicalOrFallbackUrl();
    const textToShare = `${ogTitle} ${url}`;
  
    const rawDomain = prompt("What’s your Mastodon instance?", "mastodon.social");
  
    if (!rawDomain) {
      return;
    }
  
    const domain = this.extractDomain(rawDomain);
    
    if (!domain) {
      alert("That doesn’t look quite right, please try again.");
      return;
    }
  
    const mastodonShareUrl = `https://${domain}/share?text=${encodeURIComponent(textToShare)}`;

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
