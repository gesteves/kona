import { Controller } from "@hotwired/stimulus";

const DEBOUNCE = 400;

/**
 * Makes the map preview agree with the settings form.
 *
 * ⚠️ This changes the src of the image and does not submit the form. A submit is a Turbo visit,
 * which replaces the body. Thus the field that you edit would lose the focus at each keystroke, and
 * a slider would stop during a move. The form stays a true GET form, thus the path with no
 * JavaScript still works. This code takes control only when it can.
 *
 * Each new render is one Mapbox Static Images request that Mapbox bills, and that is the purpose of
 * the wait.
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
    // This changes the preview in the page and the copy in the zoom dialog. They share a URL, thus
    // the browser gets it one time for each number of copies on the page.
    this.imageTargets.forEach((img) => {
      img.src = this.withQuery(img.src, query);
    });
    this.downloadTarget.href = this.withQuery(this.downloadTarget.href, query);
    this.save(query);
  }

  /**
   * The current values of the form, as a query string.
   *
   * Each Web Awesome control is part of the form, thus its value goes into FormData as a native
   * control does. Both parts of a boolean pair appear: a hidden "0" and the "1" of a switch. Rails
   * takes the last one, and that is what makes the switch win when it is on.
   * @returns {string}
   */
  query() {
    return new URLSearchParams(new FormData(this.formTarget)).toString();
  }

  /** Replaces the query string of a URL and keeps its path. */
  withQuery(url, query) {
    const parsed = new URL(url, window.location.origin);
    return `${parsed.pathname}?${query}`;
  }

  /** Stores the settings, thus this track has the same settings when you open it again. */
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
      // A settings save that fails is not important enough to stop the preview.
    });
  }
}
