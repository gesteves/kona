import { Controller } from "@hotwired/stimulus";

/**
 * The Share composer: the character count, the schedule fields, the label of the submit button,
 * and the time zone of the browser. The form itself posts to POST /share.
 */
export default class extends Controller {
  static targets = [
    "body", "count", "submit",
    "schedule", "scheduleFields", "date", "time", "timeZone", "label"
  ];
  static values = { limit: Number, warnAt: Number };

  connect() {
    // A restoration visit can render a snapshot that holds the button in its busy state.
    this.submitTarget.loading = false;

    // ⚠️ The date and the time carry no zone. This is what gives them a meaning, and it is the
    // reason that a date field is safe here and was not safe in the Republish dialog. When this
    // controller does not run, the field stays empty and the server falls back to TIME_ZONE.
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (zone) this.timeZoneTarget.value = zone;

    // ⚠️ Each step below waits for the definitions: `value` and `checked` are undefined on these
    // components until the browser upgrades them.
    //
    // A Turbo restoration visit renders a snapshot that holds the values and no controller state.
    // Thus the count and the schedule run at connect and not at the first event only.
    Promise.all([
      "wa-textarea", "wa-switch", "wa-date-input", "wa-time-input"
    ].map((tag) => customElements.whenDefined(tag))).then(() => {
      this.count();
      // This sets `required` as well, thus a page that renders again with the fields open keeps
      // that state.
      this.toggleSchedule();
    });
  }

  /**
   * Writes the length of the body against the limit, and colors that line.
   */
  count() {
    const length = this.graphemes(this.bodyTarget.value ?? "");

    this.countTarget.textContent = `${length} / ${this.limitValue}`;
    this.countTarget.classList.toggle("share__count--warning",
      length >= this.warnAtValue && length <= this.limitValue);
    this.countTarget.classList.toggle("share__count--over", length > this.limitValue);
  }

  /**
   * The length of a string in graphemes, which is how Bluesky counts.
   *
   * ⚠️ `String#length` gives UTF-16 code units, thus one emoji counts as 2 or more there and as 1
   * at Bluesky. The spread is the fallback: it splits by code point, which is correct for an emoji
   * with one code point and not for a family or a flag.
   * @param {string} text
   * @returns {number}
   */
  graphemes(text) {
    if (typeof Intl.Segmenter !== "function") return [...text].length;

    this.segmenter ||= new Intl.Segmenter("en", { granularity: "grapheme" });
    return [...this.segmenter.segment(text)].length;
  }

  /**
   * Shows or hides the date and the time, and follows with the label of the button.
   */
  toggleSchedule() {
    const on = this.scheduleTarget.checked;
    this.scheduleFieldsTarget.hidden = !on;

    // ⚠️ `required` follows the switch, and it is not in the markup. A required control inside a
    // hidden block would refuse "Share now", and the browser cannot show that message on an
    // element that nobody can see.
    this.dateTarget.required = on;
    this.timeTarget.required = on;

    this.relabel();
  }

  /**
   * Writes what the button does into its label.
   *
   * ⚠️ The switch is the only control that says "now" or "later", and the two states of this label
   * are what make that visible at the moment of the click. A value that is not complete gets the
   * plain word, and the `required` of the fields then stops the submit.
   */
  relabel() {
    if (!this.scheduleTarget.checked) {
      this.labelTarget.textContent = "Share now";
      return;
    }

    const when = this.scheduledAt;
    this.labelTarget.textContent = when ? `Schedule for ${when}` : "Schedule";
  }

  /**
   * Makes the submit button busy. The POST adds a job and then redirects, thus the page waits.
   *
   * ⚠️ This is on the `submit` of the form, and not on the `click` of the button. A click happens
   * **before** the browser checks the fields. Thus on a form that is not complete the submit never
   * happens and the button spins for ever.
   */
  markBusy() {
    this.submitTarget.loading = true;
  }

  /**
   * The moment that the two fields name, for the label of the button.
   * @returns {string|null} A short local date and time, or null when a field is empty.
   */
  get scheduledAt() {
    const date = this.dateTarget.value;
    const time = this.timeTarget.value;
    if (!date || !time) return null;

    // The value of each field is local wire format, thus this parses as local time and it does no
    // conversion. The zone of the browser is what the hidden field sends.
    const at = new Date(`${date}T${time}`);
    if (Number.isNaN(at.valueOf())) return null;

    return at.toLocaleString(undefined, {
      month: "short", day: "numeric", hour: "numeric", minute: "2-digit"
    });
  }

}
