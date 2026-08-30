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
    "submit", "label", "posts", "post", "template", "add", "remove", "handle",
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
      this.validate();
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
    this.validate();

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
    this.validate();
  }

  /**
   * Picks up the post that owns the handle.
   *
   * ⚠️ Firefox starts no drag at all with no data on the transfer, thus the empty string is
   * necessary and not decoration.
   */
  dragStart(event) {
    this.dragged = event.target.closest("[data-social-target='post']");
    if (!this.dragged) return;

    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", "");
    this.dragged.classList.add("social-post--dragging");
  }

  /**
   * Moves the post that the pointer holds to where the pointer is.
   *
   * ⚠️ It moves the block itself and it never rewrites a field. The names are `posts[][text]` and
   * `posts[][link]` with no index, thus **the order of the blocks in the document IS the order of
   * the thread**, and moving one is the whole change.
   */
  dragOver(event) {
    if (!this.dragged) return;

    // ⚠️ Without this the browser refuses the drop and the post springs back.
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";

    const before = this.postBelow(event.clientY);
    if (before === this.dragged) return;

    before ? this.postsTarget.insertBefore(this.dragged, before)
           : this.postsTarget.appendChild(this.dragged);
  }

  /**
   * `dragover` already moved the block, thus this only stops the browser from its own default,
   * which is to open the dragged text as a URL.
   */
  drop(event) {
    event.preventDefault();
  }

  dragEnd() {
    this.dragged?.classList.remove("social-post--dragging");
    this.dragged = null;
    this.renumber();
  }

  /**
   * The first post whose middle is below this point, which is the one to insert before.
   * @param {number} y
   * @returns {HTMLElement|undefined} Undefined puts the post at the end.
   */
  postBelow(y) {
    return this.postTargets
      .filter((post) => post !== this.dragged)
      .find((post) => {
        const box = post.getBoundingClientRect();
        return y < box.top + box.height / 2;
      });
  }

  /**
   * Moves a post with the arrow keys.
   *
   * ⚠️ A drag needs a pointer, and this page must work without one. The handle is a button and it
   * takes the focus, thus the arrow keys are the way in.
   */
  movePostByKey(event) {
    const up = event.key === "ArrowUp";
    if (!up && event.key !== "ArrowDown") return;

    event.preventDefault();
    const post = event.target.closest("[data-social-target='post']");
    const posts = this.postTargets;
    const to = posts.indexOf(post) + (up ? -1 : 1);
    if (to < 0 || to >= posts.length) return;

    up ? this.postsTarget.insertBefore(post, posts[to])
       : this.postsTarget.insertBefore(posts[to], post);

    this.renumber();
    // ⚠️ A node that moves loses the focus, thus the next arrow key would go to the document.
    post.querySelector("[data-social-target='handle']")?.focus();
  }

  /**
   * Shows the two controls of a post while there is more than one, and hides them at one.
   *
   * ⚠️ It writes no number. The field names carry no index, and the ORDER OF THE BLOCKS in the
   * document is the order of the thread. Refer to the note in _post.html.erb.
   */
  renumber() {
    const posts = this.postTargets;

    posts.forEach((post) => {
      const remove = post.querySelector("[data-social-target='remove']");
      if (remove) remove.hidden = posts.length <= 1;

      // There is nothing to reorder while there is one post.
      const handle = post.querySelector("[data-social-target='handle']");
      if (handle) handle.hidden = posts.length <= 1;
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

    this.validate();
  }

  /**
   * Writes what the button does into its label.
   *
   * ⚠️ The switch is the only control that says "now" or "later", and the two states of this label
   * are what make that visible at the moment of the click. A value that is not complete gets the
   * plain word, and the `required` of the fields then stops the submit.
   */
  relabel() {
    this.labelTarget.textContent = this.submitLabel;
  }

  /**
   * What the button will do, in its own words.
   *
   * ⚠️ **A moment that has passed is NOT a schedule**, thus the label goes back to "Post now" and
   * the action posts at once. A label of "Schedule for" over a date in the past would promise
   * something that cannot happen. `Admin::SocialController#scheduled_at` reads it the same way.
   * @returns {string}
   */
  get submitLabel() {
    if (!this.scheduleTarget.checked) return "Post now";

    const at = this.scheduledAt;
    if (!at) return "Schedule";
    if (at.getTime() <= Date.now()) return "Post now";

    return `Schedule for ${at.toLocaleString(undefined, {
      month: "short", day: "numeric", hour: "numeric", minute: "2-digit"
    })}`;
  }

  /**
   * Turns the submit button off while the draft cannot go out, and writes the label.
   *
   * ⚠️ It runs from `input` and `change` on the **form**, thus one action covers each field of
   * each post and each network. A field of a post belongs to the `social-post` controller, and
   * this one reads the DOM in place of reaching into it.
   */
  validate() {
    this.submitTarget.disabled = !this.canPost;
    this.relabel();
  }

  /**
   * @returns {boolean} True while the draft is one that the server will take.
   */
  get canPost() {
    // Every post needs words. ⚠️ This is stricter than the server, which drops a block with nothing
    // at all in it. A block that the owner added and left empty turns the button off instead, thus
    // the page never asks them to guess which post is the problem.
    const posts = this.postTargets;
    if (posts.some((post) => !post.querySelector("wa-textarea")?.value?.trim())) return false;

    // ⚠️ It reads the count line of each post in place of counting again. That line belongs to the
    // `social-post` controller, which writes it from the same `input` event: the field is the
    // target of that event and this form is above it, thus the count is already up to date here.
    if (posts.some((post) => post.querySelector(".social__count--over"))) return false;

    if (!this.networks.some((box) => box.checked && !box.disabled)) return false;

    // ⚠️ The switch is on and the two fields name no moment, thus there is nothing to schedule.
    // A moment that has **passed** is not this case: it is a complete answer, and it means "post
    // now". `#submitLabel` reads the two the same way.
    return !(this.scheduleTarget.checked && !this.scheduledAt);
  }

  /** @returns {HTMLElement[]} */
  get networks() {
    return [ ...this.element.querySelectorAll("wa-checkbox[name='networks[]']") ];
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
    return Number.isNaN(at.valueOf()) ? null : at;
  }
}
