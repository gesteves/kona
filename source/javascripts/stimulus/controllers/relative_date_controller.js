import { Controller } from "@hotwired/stimulus";
import { formatDistanceToNow } from "date-fns";

export default class extends Controller {
  static values = {
    datetime: String,
    addSuffix: { type: Boolean, default: true },
    includeSeconds: { type: Boolean, default: true },
  };

  connect() {
    if (this.hasDatetimeValue) {
      this.updateRelativeTime();
    }
  }

  disconnect() {
    if (this.timer) {
      clearTimeout(this.timer);
    }
  }

  updateRelativeTime() {
    const now = new Date();
    const timestamp = new Date(this.datetimeValue);
    const differenceInSeconds = Math.floor((now - timestamp) / 1000);

    const relativeDate = formatDistanceToNow(timestamp, {
      addSuffix: this.addSuffixValue,
      includeSeconds: this.includeSecondsValue,
    });

    this.element.textContent = relativeDate;

    // Determine the update interval
    let nextUpdate;
    if ((differenceInSeconds < 60) && this.includeSecondsValue) {
      nextUpdate = 1000; // Update every 1 second
    } else if (differenceInSeconds < 3600) {
      nextUpdate = 60000; // Update every 1 minute
    } else if (differenceInSeconds < 86400) {
      nextUpdate = 3600000; // Update every 1 hour
    } else {
      return; // Stop updating after 1 day
    }

    this.timer = setTimeout(() => this.updateRelativeTime(), nextUpdate);
  }
}
