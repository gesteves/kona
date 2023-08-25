import { Controller } from "stimulus";

export default class extends Controller {
  static classes = ["hidden"]

  connect() {
    if (navigator.share) {
      this.element.classList.remove(this.hiddenClass);
    }
  }

  getCanonicalOrFallbackUrl() {
    const canonicalLink = document.querySelector('link[rel="canonical"]');
    return canonicalLink ? canonicalLink.href : window.location.href;
  }

  share() {
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
}
