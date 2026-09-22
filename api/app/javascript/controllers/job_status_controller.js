import { Controller } from "@hotwired/stimulus";
import { visit } from "@hotwired/turbo";

const INTERVAL = 5000;

/**
 * Gets a list again while a background job still works on one of its rows.
 *
 * The Maps page and the media uploader both use it: Mapbox and Contentful each publish
 * asynchronously, and the origin can send nothing to the page. Thus the page asks. It reads a
 * status-only endpoint and does not load the page again, and it renders again only when a status
 * changes. A publish takes one or two minutes, thus most reads find no change.
 *
 * A row carries `data-job-status-id` and `data-job-status-state`, and the endpoint answers
 * `{ id: state }`.
 * ⚠️ **The in-progress state is the word `processing`**, in this file and in each store that
 * feeds it. A store that uses another word polls for all time.
 */
export default class extends Controller {
  static values = { url: String };

  connect() {
    this.poll();
  }

  /**
   * Stops the timer and the request that is out. ⚠️ Without the abort, a response that lands
   * after a navigation reads the detached element, finds its rows still in the publish state, and
   * later loads whatever page the owner moved to.
   */
  disconnect() {
    this.stop();
    this.aborter?.abort();
  }

  /** Starts the timer for the next check, or stops if no upload is in progress. */
  poll() {
    this.stop();
    if (!this.element.isConnected || !this.pendingIds().length) return;

    this.timer = setTimeout(() => this.check(), INTERVAL);
  }

  async check() {
    this.aborter?.abort();
    this.aborter = new AbortController();
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" },
        signal: this.aborter.signal,
      });
      if (!this.element.isConnected) return;
      if (!response.ok) return this.poll();

      const statuses = await response.json();
      if (this.changed(statuses)) {
        // Replace the history entry and do not add one, thus these reads do not fill the
        // history.
        visit(window.location.href, { action: "replace" });
        return;
      }
    } catch {
      // A request that fails needs no message, because the next check tries again.
    }

    this.poll();
  }

  /** @returns {string[]} The ids of the rows that the server last rendered in the in-progress state. */
  pendingIds() {
    return this.rows()
      .filter((row) => row.dataset.jobStatusState === "processing")
      .map((row) => row.dataset.jobStatusId);
  }

  /**
   * Tells if a row that the server rendered in the in-progress state changed. This includes a row that
   * a person deleted in another tab, which is then absent from the response.
   * @returns {boolean}
   */
  changed(statuses) {
    return this.rows().some((row) => {
      if (row.dataset.jobStatusState !== "processing") return false;
      return statuses[row.dataset.jobStatusId] !== "processing";
    });
  }

  rows() {
    return Array.from(this.element.querySelectorAll("[data-job-status-id]"));
  }

  stop() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }
}
