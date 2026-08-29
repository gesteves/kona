import { Controller } from "@hotwired/stimulus";

/**
 * The Social media page: the posts of a thread, the schedule fields, the label of the submit
 * button, and the time zone of the browser. The form posts to POST /social.
 *
 * ⚠️ The count and the link preview of one post are NOT here. Each block is its own `social-post`
 * controller, thus this one never reaches into a block and never needs an index.
 */
export default class extends Controller {
  static targets = [
    "submit", "label", "posts", "post", "postLabel", "template", "add", "remove",
    "schedule", "scheduleFields", "date", "time", "timeZone",
  ];
  static values = { maxPosts: Number };

  connect() {
    // A restoration visit can render a snapshot that holds the button in its busy state.
    this.submitTarget.loading = false;

    // ⚠️ The date and the time carry no zone. This is what gives them a meaning, and it is the
    // reason that a date field is safe here and was not safe in the Republish dialog. With no
    // JavaScript the field stays empty and the server falls back to TIME_ZONE.
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (zone) this.timeZoneTarget.value = zone;

    // ⚠️ Each step below waits for the definitions: `value` and `checked` are undefined on these
    // components until the browser upgrades them.
    //
    // A Turbo restoration visit renders a snapshot that holds the values and no controller state.
    // Thus the schedule runs at connect and not at the first event only.
    Promise.all(
      ["wa-switch", "wa-date-input", "wa-time-input"].map((tag) => customElements.whenDefined(tag))
    ).then(() => {
      // This sets `required` as well, thus a page that renders again with the fields open keeps
      // that state.
      this.toggleSchedule();
    });

    this.renumber();
  }

  /**
   * Adds one empty post at the end of the thread, from the template.
   *
   * ⚠️ The content of a <template> is inert: the browser renders none of it and its fields are not
   * in the form. Only this clone puts a block in the document.
   */
  addPost(event) {
    event.preventDefault();
    if (this.postTargets.length >= this.maxPostsValue) return;

    this.postsTarget.appendChild(this.templateTarget.content.cloneNode(true));
    this.renumber();

    // The words are the point of a new post, thus the caret goes there.
    const added = this.postTargets[this.postTargets.length - 1];
    added.querySelector("wa-textarea")?.focus();
  }

  /**
   * Removes the post that holds the control that was pressed.
   */
  removePost(event) {
    event.preventDefault();
    if (this.postTargets.length <= 1) return;

    event.target.closest("[data-social-target='post']")?.remove();
    this.renumber();
  }

  /**
   * Writes "N/M" into each label, and hides Remove while there is one post.
   *
   * ⚠️ This is the ONLY numbering, and it is for the reader. The field names carry no index, thus
   * nothing here changes what the form sends. Refer to the note in _post.html.erb.
   *
   * ⚠️ The target is `postLabel` and NOT `label`. The submit button owns `label`, and one name for
   * both made `labelTarget` find the first post and write "Post now" into it.
   */
  renumber() {
    const posts = this.postTargets;

    posts.forEach((post, index) => {
      const label = post.querySelector("[data-social-target='postLabel']");
      if (label) label.textContent = posts.length > 1 ? `${index + 1}/${posts.length}` : "";

      const remove = post.querySelector("[data-social-target='remove']");
      if (remove) remove.hidden = posts.length <= 1;
    });

    this.addTarget.disabled = posts.length >= this.maxPostsValue;
  }

  /**
   * Shows or hides the date and the time, and follows with the label of the button.
   */
  toggleSchedule() {
    const on = this.scheduleTarget.checked;
    this.scheduleFieldsTarget.hidden = !on;

    // ⚠️ `required` follows the switch, and it is not in the markup. A required control inside a
    // hidden block would refuse "Post now", and the browser cannot show that message on an element
    // that nobody can see.
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
   * Makes the submit button busy.
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
