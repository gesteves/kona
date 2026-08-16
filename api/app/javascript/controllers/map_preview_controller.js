import { Controller } from "@hotwired/stimulus";

const DEBOUNCE = 400;

/**
 * Keeps the map preview in step with the settings form.
 *
 * ⚠️ Rewrites the image's src rather than submitting the form. A submit would be a Turbo visit,
 * which replaces the body — so the field being edited would lose focus on every keystroke, and a
 * slider would stop tracking mid-drag. The form stays a real GET form so the no-JS path still
 * works; this just takes over when it can.
 *
 * Each rebuild is one billed Mapbox Static Images request, which is what the debounce is for.
 */
export default class extends Controller {
  static targets = ["form", "image", "download"];
  static values = { saveUrl: String };

  connect() {
    this.schedule = this.schedule.bind(this);
    this.formTarget.addEventListener("input", this.schedule);
    this.formTarget.addEventListener("change", this.schedule);
  }

  disconnect() {
    this.formTarget.removeEventListener("input", this.schedule);
    this.formTarget.removeEventListener("change", this.schedule);
    if (this.timer) clearTimeout(this.timer);
  }

  schedule() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => this.update(), DEBOUNCE);
  }

  update() {
    const query = this.query();
    // Both the inline preview and the zoom dialog's copy. They share a URL, so the browser fetches
    // it once however many are on the page.
    this.imageTargets.forEach((img) => {
      img.src = this.withQuery(img.src, query);
    });
    this.downloadTarget.href = this.withQuery(this.downloadTarget.href, query);
    this.save(query);
  }

  /**
   * The form's current values as a query string.
   *
   * Web Awesome's controls are form-associated, so they land in FormData like native ones. The
   * boolean pairs (a hidden "0" plus a switch's "1") both appear; Rails takes the last, which is
   * what makes the switch win when it's on.
   * @returns {string}
   */
  query() {
    return new URLSearchParams(new FormData(this.formTarget)).toString();
  }

  /** Swaps a URL's query string, keeping its path. */
  withQuery(url, query) {
    const parsed = new URL(url, window.location.origin);
    return `${parsed.pathname}?${query}`;
  }

  /** Persists the settings so reopening this track picks up where the tweaking left off. */
  save(query) {
    if (!this.hasSaveUrlValue) return;

    fetch(this.saveUrlValue, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content ?? ""
      },
      body: query
    }).catch(() => {
      // Losing a settings save is not worth interrupting the preview for.
    });
  }
}
