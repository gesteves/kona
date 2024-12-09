import { Controller } from "@hotwired/stimulus";
import { formatDistanceToNow } from "date-fns";

export default class extends Controller {
  static values = {
    datetime: String,
  };

  connect() {
    if (this.hasDatetimeValue) {
      const relativeDate = formatDistanceToNow(new Date(this.datetimeValue), {
        addSuffix: true,
      });

      this.element.textContent = relativeDate;
    }
  }
}
