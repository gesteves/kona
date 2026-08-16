import { Controller } from "@hotwired/stimulus";
import { visit } from "@hotwired/turbo";

const INTERVAL = 5000;

/**
 * Refreshes the Maps list while Mapbox is still publishing an upload.
 *
 * Mapbox's tiling service is asynchronous and there's nothing to push from the origin, so the page
 * asks. It polls a status-only endpoint rather than reloading, and only re-renders once a status
 * actually changes — a publish takes a minute or two, so most ticks find nothing.
 */
export default class extends Controller {
  static values = { url: String };

  connect() {
    this.poll();
  }

  disconnect() {
    this.stop();
  }

  /** Schedules the next check, or stops if nothing is in flight. */
  poll() {
    this.stop();
    if (!this.pendingIds().length) return;

    this.timer = setTimeout(() => this.check(), INTERVAL);
  }

  async check() {
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "application/json" } });
      if (!response.ok) return this.poll();

      const statuses = await response.json();
      if (this.changed(statuses)) {
        // Replace rather than push, so polling doesn't stack history entries.
        visit(window.location.href, { action: "replace" });
        return;
      }
    } catch {
      // A dropped request is not worth surfacing; the next tick tries again.
    }

    this.poll();
  }

  /** @returns {string[]} Ids of rows the server last rendered as still publishing. */
  pendingIds() {
    return this.rows()
      .filter((row) => row.dataset.mapStatusState === "processing")
      .map((row) => row.dataset.mapStatusId);
  }

  /**
   * Whether any row the server rendered as publishing has since moved on — including by being
   * deleted in another tab, which drops it from the response entirely.
   * @returns {boolean}
   */
  changed(statuses) {
    return this.rows().some((row) => {
      if (row.dataset.mapStatusState !== "processing") return false;
      return statuses[row.dataset.mapStatusId] !== "processing";
    });
  }

  rows() {
    return Array.from(this.element.querySelectorAll("[data-map-status-id]"));
  }

  stop() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }
}
