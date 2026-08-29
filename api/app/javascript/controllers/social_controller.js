import { Controller } from "@hotwired/stimulus";

// How long the link field must be quiet before this reads the card. Each preview is one request of
// this app, which then reads the page of another host.
const PREVIEW_DEBOUNCE = 600;

/**
 * The Social media page: the character count, the schedule fields, the label of the submit button,
 * and the time zone of the browser. The form itself posts to POST /social.
 */
export default class extends Controller {
  static targets = [
    "body", "count", "submit", "link", "spinner", "preview", "previewImage", "previewHost",
    "previewTitle", "previewDescription", "previewKind",
    "schedule", "scheduleFields", "date", "time", "timeZone", "label"
  ];
  static values = { limit: Number, warnAt: Number, previewUrl: String };

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
      // A page that renders again after a refusal holds a link, thus the card comes back with it.
      this.preview();
    });
  }

  /**
   * Writes the length of the body against the limit, and colors that line.
   */
  count() {
    const length = this.graphemes(this.bodyTarget.value ?? "");

    this.countTarget.textContent = `${length} / ${this.limitValue}`;
    this.countTarget.classList.toggle("social__count--warning",
      length >= this.warnAtValue && length <= this.limitValue);
    this.countTarget.classList.toggle("social__count--over", length > this.limitValue);
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
    // hidden block would refuse "Post now", and the browser cannot show that message on an
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
      this.labelTarget.textContent = "Post now";
      return;
    }

    const when = this.scheduledAt;
    this.labelTarget.textContent = when ? `Schedule for ${when}` : "Schedule";
  }

  /**
   * Waits for the typing to stop, then reads the card.
   *
   * ⚠️ Each preview is one request of this app, which then reads the page. Thus it waits, and it
   * does not read at each keystroke.
   */
  schedulePreview() {
    clearTimeout(this.previewTimer);

    // An empty field asks for nothing, thus it waits for nothing either.
    if (!this.linkTarget.value?.trim()) {
      this.busy(false);
      return this.hidePreview();
    }

    // ⚠️ It spins from the keystroke and not from the request. The debounce is most of the wait,
    // and a field that does nothing for 600ms reads as a field that is broken.
    this.busy(true);
    this.previewTimer = setTimeout(() => this.preview(), PREVIEW_DEBOUNCE);
  }

  /**
   * Reads the card of the link and shows it.
   *
   * ⚠️ The browser cannot read another site by itself: the CSP of the admin has `connect-src
   * :self`, and another host sends no CORS header. Thus this asks this app, and the picture comes
   * from this app as well, because `img-src` is `:self`.
   */
  async preview() {
    const url = this.linkTarget.value?.trim() ?? "";
    if (!url) {
      this.busy(false);
      return this.hidePreview();
    }

    // ⚠️ Each call takes the next number, and only the newest one may write. A request that is
    // still out when the owner types again must not describe a link that they already replaced,
    // and must not stop the spinner of the request that replaced it.
    this.previewSeq = (this.previewSeq ?? 0) + 1;
    const seq = this.previewSeq;

    try {
      const response = await fetch(`${this.previewUrlValue}?${new URLSearchParams({ url })}`, {
        headers: { Accept: "application/json" }
      });
      if (seq !== this.previewSeq) return;

      if (!response.ok) return this.hidePreview();
      this.showPreview(await response.json());
    } catch {
      if (seq === this.previewSeq) this.hidePreview();
    } finally {
      if (seq === this.previewSeq) this.busy(false);
    }
  }

  /**
   * Shows or hides the spinner in the link field.
   * @param {boolean} on
   */
  busy(on) {
    this.spinnerTarget.hidden = !on;
  }

  /**
   * @param {object} card The answer of the preview action.
   */
  showPreview(card) {
    this.previewHostTarget.textContent = card.host ?? "";
    this.previewTitleTarget.textContent = card.title ?? "";
    this.previewDescriptionTarget.textContent = card.description ?? "";

    // ⚠️ `withMedia` follows the picture. <wa-card> has no `:has-slotted` to read, thus that flag
    // is the only thing that tells it to draw the media section. A card with the flag and no
    // picture draws an empty band above the text.
    this.previewImageTarget.hidden = !card.image_path;
    this.previewTarget.withMedia = !!card.image_path;
    if (card.image_path) this.previewImageTarget.src = card.image_path;

    // This is the thing that the owner cannot know until after the post without it.
    this.previewKindTarget.textContent = card.standard_site ? "Standard.site" : "Open Graph";
    this.previewKindTarget.variant = card.standard_site ? "success" : "neutral";

    this.previewTarget.hidden = false;
  }

  /**
   * Hides the card, and drops the picture so a stale one never shows with a new link.
   */
  hidePreview() {
    this.previewTarget.hidden = true;
    this.previewTarget.withMedia = false;
    this.previewImageTarget.hidden = true;
    this.previewImageTarget.removeAttribute("src");
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
