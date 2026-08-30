import { Controller } from "@hotwired/stimulus";
import { i18nTable, t } from "../lib/i18n";

/**
 * The Republish dialog: one delay in minutes, where zero is "now".
 *
 * The label of the submit button says what the current value does. That label is the only thing
 * that tells the owner "now" from "later", thus it must follow each edit of the field.
 */
export default class extends Controller {
  static targets = ["form", "minutes", "submit", "label"];

  connect() {
    // ⚠️ The words come from the locale file, through the `data-admin-i18n` attribute. Read the
    // table here: it is synchronous, and `relabel` runs at each keystroke.
    this.words = i18nTable(this.element);
    // A restoration visit of Turbo can render a snapshot that has the button in its busy state.
    this.submitTarget.loading = false;
    // ⚠️ It waits for the definition. Before the upgrade, `value` of the field is undefined, and the
    // label would then stay at the plain word for a value that is correct.
    customElements.whenDefined("wa-number-input").then(() => this.relabel());
  }

  /**
   * Writes what the submit button does into its label.
   *
   * A value outside the limits gets the plain word, because the delay is then unknown. The field is
   * `required` and it has a min and a max, thus the browser stops that submit.
   */
  relabel() {
    const minutes = this.minutes;

    if (minutes === null) {
      this.labelTarget.textContent = t(this.words, "plain");
    } else if (minutes === 0) {
      this.labelTarget.textContent = t(this.words, "now");
    } else {
      this.labelTarget.textContent = t(this.words, "scheduled", { count: minutes });
    }
  }

  /**
   * Submits the form from the field, because the submit button is in a slot outside that form.
   *
   * ⚠️ It stops the default action first. Thus one Enter gives one submit, and it does that whether
   * or not the browser finds the button through its `form` attribute.
   * @param {KeyboardEvent} event
   */
  submitOnEnter(event) {
    if (event.key !== "Enter") return;

    event.preventDefault();
    this.formTarget.requestSubmit();
  }

  /**
   * Makes the submit button busy, because the POST goes on to a full page load.
   */
  markBusy() {
    this.submitTarget.loading = true;
  }

  /**
   * The delay of the field, or null when it is empty or outside the limits of the markup.
   * @returns {number|null}
   */
  get minutes() {
    const value = this.minutesTarget.value;
    if (value === "") return null;

    const minutes = Number(value);
    const min = Number(this.minutesTarget.getAttribute("min"));
    const max = Number(this.minutesTarget.getAttribute("max"));
    if (!Number.isInteger(minutes) || minutes < min || minutes > max) return null;

    return minutes;
  }
}
