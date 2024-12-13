import { Controller } from "@hotwired/stimulus";
import { formatDistanceToNow, minutesToSeconds, hoursToSeconds, hoursToMilliseconds, minutesToMilliseconds, secondsToMilliseconds } from "date-fns";

export default class extends Controller {
  static values = {
    datetime: String,
    addSuffix: { type: Boolean, default: true },
    includeSeconds: { type: Boolean, default: true },
    liveUpdating: { type: Boolean, default: true }
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

    if (!this.liveUpdatingValue) {
      return;
    }

    // Determine the update interval
    let nextUpdate;
    if ((differenceInSeconds < minutesToSeconds(1)) && this.includeSecondsValue) {
      nextUpdate = secondsToMilliseconds(1); // Update every second
    } else if (differenceInSeconds < minutesToSeconds(45)) {
      nextUpdate = minutesToMilliseconds(1); // Update every minute
    } else if (differenceInSeconds < hoursToSeconds(24)) {
      nextUpdate = hoursToMilliseconds(1); // Update every hour
    } else {
      return; // Stop updating after 1 day
    }

    this.timer = setTimeout(() => this.updateRelativeTime(), nextUpdate);
  }
}
