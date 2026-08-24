import { Controller } from "@hotwired/stimulus";

/**
 * The Republish dialog: it selects an immediate build or a build at a time that the owner picks.
 *
 * The server knows UTC only, thus this code gives it the zone of the browser and fills the two
 * fields with the local date and time.
 */
export default class extends Controller {
  static targets = ["schedule", "later", "date", "time", "zone"];

  connect() {
    this.zoneTarget.value = Intl.DateTimeFormat().resolvedOptions().timeZone || "";
    this.stamp();
    this.toggle();
  }

  /**
   * Puts the current local date and time into the two fields.
   *
   * ⚠️ It reads the parts of the local Date, and it never uses toISOString(). That method gives
   * UTC, thus the fields would show a time that the owner does not have on the clock.
   * This runs at connect and at each `wa-show` of the dialog, thus a second open is never old.
   */
  stamp() {
    const now = new Date();
    const pad = (value) => String(value).padStart(2, "0");

    this.dateTarget.value = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
    this.timeTarget.value = `${pad(now.getHours())}:${pad(now.getMinutes())}`;
  }

  /**
   * Shows the date and the time for "later", and hides them for "now".
   *
   * A disabled control submits nothing and skips its own validation. Thus the fields cannot stop a
   * submit while they are out of view.
   */
  toggle() {
    const later = this.scheduleTarget.value === "later";

    this.laterTarget.hidden = !later;
    for (const field of [this.dateTarget, this.timeTarget]) {
      field.required = later;
      field.disabled = !later;
    }
  }
}
