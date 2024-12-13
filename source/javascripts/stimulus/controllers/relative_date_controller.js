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
    const differenceInSeconds = Math.abs(Math.floor((now - timestamp) / 1000));

    const relativeDate = formatDistanceToNow(timestamp, {
      addSuffix: this.addSuffixValue,
      includeSeconds: this.includeSecondsValue,
    });

    this.element.textContent = relativeDate;

    if (!this.liveUpdatingValue) {
      return;
    }

    // Determine the update interval.
    // This roughly matches the formatting used by formatDistanceToNow: https://date-fns.org/v4.1.0/docs/formatDistanceToNow
    let nextUpdate;
    if ((differenceInSeconds < minutesToSeconds(1)) && this.includeSecondsValue) {
      // If the date is less than a minute ago, update every second.
      nextUpdate = secondsToMilliseconds(1);
    } else if (differenceInSeconds < minutesToSeconds(45)) {
      // If the date is less than 45 minutes ago, update every minute.
      nextUpdate = minutesToMilliseconds(1);
    } else if (differenceInSeconds < hoursToSeconds(24)) {
      // If the date is less than a day ago, update every hour.
      nextUpdate = hoursToMilliseconds(1);
    } else {
      // Stop updating after 1 day
      return;
    }

    this.timer = setTimeout(() => this.updateRelativeTime(), nextUpdate);
  }
}
