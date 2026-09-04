import { Controller } from "@hotwired/stimulus";
import { i18nTable, t } from "../lib/i18n";
import { toast } from "../lib/toast";

/**
 * The Republish dialog: one delay in minutes, where zero is "now".
 *
 * The label of the submit button says what the current value does. That label is the only thing
 * that tells the owner "now" from "later", thus it must follow each edit of the field.
 */
export default class extends Controller {
  static targets = ["form", "minutes", "label"];

  connect() {
    // ⚠️ The words come from the locale file, through the `data-admin-i18n` attribute. Read the
    // table here: it is synchronous, and `relabel` runs at each keystroke.
    this.words = i18nTable(this.element);
    // ⚠️ The attribute, and not the property: it is the value that the server rendered, thus a
    // submit can put it back after the owner picked another delay.
    this.defaultMinutes = this.minutesTarget.getAttribute("value");
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
   * Starts the republish with fetch, closes the dialog, and puts the answer in a toast.
   *
   * ⚠️ **It stops the native submit.** A submit that goes through navigates the admin, and the page
   * below the dialog renders again. The owner opens this dialog from each admin page, thus that
   * navigation would take away a draft of the Social media page that nothing has saved.
   *
   * ⚠️ It sends the CSRF token in a header. The admin does not skip the forgery protection.
   * @param {SubmitEvent} event
   */
  async submit(event) {
    event.preventDefault();
    this.close();

    try {
      const response = await fetch(this.formTarget.action, {
        method: "POST",
        headers: { Accept: "application/json", ...this.csrfHeader },
        body: new FormData(this.formTarget),
      });
      const answer = await response.json().catch(() => ({}));
      toast(answer.message || t(this.words, "unreachable"), response.ok ? "success" : "danger");
    } catch {
      toast(t(this.words, "unreachable"), "danger");
    }
  }

  /**
   * Closes the dialog and puts the delay back to the value of the server.
   *
   * ⚠️ The dialog stays in the DOM after a submit, thus a delay that the owner picked one time
   * would still be there the next time that they open it.
   */
  close() {
    this.element.open = false;
    this.minutesTarget.value = this.defaultMinutes;
    this.relabel();
  }

  /**
   * The CSRF token of the page, as a header.
   *
   * ⚠️ `csrf_meta_tags` renders nothing where the forgery protection is off, which is the test
   * environment. Thus this gives an empty object there and the header is absent.
   * @returns {object}
   */
  get csrfHeader() {
    const token = document.querySelector("meta[name='csrf-token']")?.content;

    return token ? { "X-CSRF-Token": token } : {};
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
