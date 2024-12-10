import { Controller } from "@hotwired/stimulus";
import { formatDistanceToNow } from "date-fns";

export default class extends Controller {
  static values = {
    datetime: String,
    addSuffix: { type: Boolean, default: true }
  };

  /** 
   * Replaces an absolute timestamp with a relative one.
   */
  connect() {
    if (this.hasDatetimeValue) {
      const relativeDate = formatDistanceToNow(new Date(this.datetimeValue), {
        addSuffix: this.addSuffixValue,
      });

      this.element.textContent = relativeDate;
    }
  }
}
