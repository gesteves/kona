import { Controller } from "@hotwired/stimulus";
import { i18nTable, t } from "../lib/i18n";
import { hasLinks } from "../lib/markdown_links";
import { MentionRows } from "../lib/mention_rows";
import { PreviewPanel } from "../lib/preview_panel";

// The words of a post, and one photo tile of a post. ⚠️ The selector of the words names the
// field: a tile holds a `wa-textarea` of its own for the alt text, and a bare tag name would
// find that one in a post whose words come after it.
const BODY = "wa-textarea[name='posts[][text]']";
const PHOTO = "[data-social-post-target='photo']";

/**
 * The Social media page: the posts of a thread, the schedule fields, the label of the submit
 * button, and the time zone of the browser. The form posts to POST /social.
 *
 * ⚠️ The count and the link preview of one post are NOT here: each block is its own
 * `social-post` controller. This one asks a block two things only, through `postController`:
 * `blocked` (refer to `canPost`) and `count()` (refer to `pushMentions`).
 */
export default class extends Controller {
  static targets = [
    "submit", "label", "posts", "post", "template", "add", "remove", "handle",
    "schedule", "scheduleFields", "date", "time", "timeZone",
    "mentions", "mentionRows", "mentionTemplate", "mention",
    "previewTab", "previewPanel", "previewSpinner", "previewBody", "previewEmpty",
    "previewGroupTemplate", "previewRowTemplate", "removeDialog", "markdownNetwork", "topicField",
  ];
  static values = { maxPosts: Number, previewUrl: String };

  connect() {
    // ⚠️ The words come from the locale file, through the `data-admin-i18n` attribute. Read the
    // table here: `submitLabel` runs at each keystroke and it must be synchronous.
    this.words = i18nTable(this.element);
    // A restoration visit can render a snapshot that holds the button in its busy state.
    this.submitTarget.loading = false;

    // The mention rows and the Preview panel each keep their own state. Refer to lib/.
    this.mentionMap = new MentionRows({
      section: this.mentionsTarget,
      container: this.mentionRowsTarget,
      template: this.mentionTemplateTarget,
      rows: () => this.mentionTargets,
      texts: () => this.postTargets.map((post) => post.querySelector(BODY)?.value ?? ""),
      changed: () => {
        this.pushMentions();
        this.submitTarget.disabled = !this.canPost;
      },
    });
    this.panel = new PreviewPanel({
      form: this.element,
      url: () => this.previewUrlValue,
      body: this.previewBodyTarget,
      empty: this.previewEmptyTarget,
      spinner: this.previewSpinnerTarget,
      groupTemplate: this.previewGroupTemplateTarget,
      rowTemplate: this.previewRowTemplateTarget,
      networks: () => this.networks,
      words: this.words,
    });

    // The reason that `applyBlueskyOnly` turned each row off, by network key. ⚠️ A row with no
    // entry counts as null, thus the first `validate()` of a draft with no Markdown link and no
    // photo does nothing at all. Without that the restore branch would run at connect and untick
    // each row that the server rendered as ticked.
    this.offReasons = new Map();

    // ⚠️ The date and the time carry no zone, and this value gives them one. With no JavaScript
    // the field stays empty and the server falls back to TIME_ZONE.
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (zone) this.timeZoneTarget.value = zone;

    // ⚠️ Each step below waits for the definitions: `value` and `checked` are undefined on these
    // components until the browser upgrades them. `wa-input` is in the list for the mention
    // fields: a read before the upgrade would write an empty value over each handle.
    //
    // A Turbo restoration visit renders a snapshot that holds the values and no controller state.
    // Thus the schedule runs at connect and not at the first event only.
    Promise.all(
      ["wa-switch", "wa-date-input", "wa-time-input", "wa-input"]
        .map((tag) => customElements.whenDefined(tag))
    ).then(() => {
      // This sets `required` as well, thus a page that renders again with the fields open keeps
      // that state.
      this.toggleSchedule();
      this.validate();
    });

    this.renumber();
  }

  /**
   * Stops the timers and the request that is out. ⚠️ Each controller of the admin does this: a
   * Turbo visit disconnects the controller, and a timer or a response that lands after it would
   * write into a page that is gone.
   */
  disconnect() {
    this.mentionMap.stop();
    this.panel.stop();
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

    // ⚠️ The map goes on the block BEFORE it joins the document, thus the new block counts
    // correctly at its own `connect()`.
    const added = this.templateTarget.content.cloneNode(true);
    const block = added.querySelector("[data-social-target='post']");
    if (block) block.dataset.socialPostBlueskyMentions = this.mentionMap.blueskyJson;

    this.postsTarget.appendChild(added);
    this.renumber();
    this.validate();

    // The words are the point of a new post, thus the caret goes there.
    this.postTargets[this.postTargets.length - 1]?.querySelector(BODY)?.focus();
  }

  /**
   * Removes the post that holds the control that was pressed.
   *
   * ⚠️ A post that holds something asks first, because nothing here can put it back. A block
   * that is still empty goes at once.
   */
  removePost(event) {
    event.preventDefault();
    if (this.postTargets.length <= 1) return;

    const post = event.target.closest("[data-social-target='post']");
    if (!post) return;
    if (!this.hasContent(post)) return this.dropPost(post);

    this.pendingRemoval = post;
    this.removeDialogTarget.open = true;
  }

  /**
   * Removes the post that the dialog asked about.
   */
  confirmRemove() {
    const post = this.pendingRemoval;

    // ⚠️ It reads the reference BEFORE it closes the dialog. The close fires `wa-hide`, which calls
    // `clearRemoval`, thus the order here is what keeps the post to remove.
    this.removeDialogTarget.open = false;
    if (post) this.dropPost(post);
  }

  /**
   * Forgets the post that the dialog asked about.
   *
   * ⚠️ It runs at `wa-hide`, thus Cancel, the Escape key, and the close button all reach it.
   * ⚠️ It is `wa-hide` and NOT `wa-after-hide`: the dialog can fire the first one with no second
   * one after it.
   */
  clearRemoval() {
    this.pendingRemoval = null;
  }

  /**
   * Takes one post out of the thread.
   * @param {HTMLElement} post
   */
  dropPost(post) {
    const index = this.postTargets.indexOf(post);
    post.remove();
    this.renumber();
    this.validate();
    this.focusAfterRemoval(index);
  }

  /**
   * Puts the focus on a control that is still there. ⚠️ The post that held the focused control is
   * gone, and a focus that falls to the body sends the next Tab to the top of the page.
   * @param {number} index The index that the removed post had.
   */
  focusAfterRemoval(index) {
    const posts = this.postTargets;
    const next = posts[Math.min(index, posts.length - 1)];
    const control =
      next?.querySelector("[data-social-target='handle']:not([hidden])") ||
      next?.querySelector(BODY) ||
      this.addTarget;
    control?.focus();
  }

  /**
   * @param {HTMLElement} post
   * @returns {boolean} True when that post holds words, a link, or a photo.
   */
  hasContent(post) {
    return !!(post.querySelector(BODY)?.value?.trim() ||
              post.querySelector("wa-input[type='url']")?.value?.trim() ||
              post.querySelector(PHOTO));
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
   * ⚠️ It moves the block itself and it never rewrites a field. The field names have no index,
   * thus the order of the blocks in the document IS the order of the thread.
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
   * Shows the two controls of a post while there is more than one, and hides them at one. It
   * writes no number: refer to `dragOver`.
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
   * Writes what the button does into its label. A value that is not complete gets the plain
   * word, and the `required` of the fields then stops the submit.
   */
  relabel() {
    this.labelTarget.textContent = this.submitLabel;
  }

  /**
   * What the button will do, in its own words.
   *
   * ⚠️ A moment that has passed is NOT a schedule, thus the label goes back to "Post now" and the
   * action posts at once. `SocialDraft#scheduled_at` reads it the same way.
   * @returns {string}
   */
  get submitLabel() {
    if (!this.scheduleTarget.checked) return t(this.words, "post_now");

    const at = this.scheduledAt;
    if (!at) return t(this.words, "incomplete");
    if (at.getTime() <= Date.now()) return t(this.words, "post_now");

    return t(this.words, "scheduled", {
      at: at.toLocaleString(undefined, {
        month: "short", day: "numeric", hour: "numeric", minute: "2-digit"
      })
    });
  }

  /**
   * Turns the submit button off while the draft cannot go out, and writes the label.
   *
   * ⚠️ It runs from `input` and `change` on the form, thus one action covers each field of each
   * post and each network.
   */
  validate() {
    // ⚠️ The order matters. `pushMentions` recounts each post AT ONCE, and `canPost` below reads
    // the count line that the recount wrote. A push that arrived later would leave the button on
    // for a draft that is already past the limit.
    this.mentionMap.read();
    this.pushMentions();
    this.mentionMap.scheduleScan();
    // ⚠️ It runs BEFORE `canPost`, which reads the ticks that this method can change.
    this.applyBlueskyOnly();
    // ⚠️ And AFTER it, because a Markdown link unticks and disables the Threads row.
    this.applyTopic();

    this.submitTarget.disabled = !this.canPost;
    // ⚠️ This is NOT `canPost`. A draft that is past the limit, or that ticks no network, is exactly
    // the draft that the owner wants to look at.
    this.previewTabTarget.disabled = !this.canPreview;

    // ⚠️ A network that the owner unticks goes away at once, with no request. The refresh below
    // is for the mentions and the topic, which change the text that only the server can write.
    this.panel.filter();
    if (this.previewActive) this.panel.scheduleRefresh();

    this.relabel();
  }

  /**
   * Turns the rows of Mastodon and Threads off while the draft holds a Markdown link, or more
   * photos on one post than the row takes.
   *
   * ⚠️ Only Bluesky has rich text: the other two would post `[my post](https://…)` as plain
   * words. Each row takes its own number of photos, from its `data-max-photos`.
   * `SocialDraftValidator` refuses such a request as well.
   *
   * ⚠️ It does nothing to a row while the reason of that row has not changed. This runs at each
   * keystroke, thus a restore at each one would put back a tick that the owner took off.
   *
   * ⚠️ It reads the `markdownNetwork` targets, which the view puts on the CONNECTED rows of those
   * two networks alone. A row with no account must never come back on.
   */
  applyBlueskyOnly() {
    const markdown = this.hasMarkdown;
    const most = this.mostPhotos;

    this.markdownNetworkTargets.forEach((box) => {
      const reason = markdown ? "markdown" : most > Number(box.dataset.maxPhotos ?? 0) ? "photos" : null;
      const wasReason = this.offReasons.get(box.value) ?? null;
      if (reason === wasReason) return;

      const on = !!reason;
      const wasOn = !!wasReason;
      this.offReasons.set(box.value, reason);

      if (on && !wasOn) {
        // ⚠️ It keeps the tick that the owner had, thus a link that they write and then remove
        // gives the draft its networks back. It keeps a value that is already there, because Turbo
        // puts this attribute in its snapshot and a restoration visit reads the boxes after the
        // untick.
        if (!("wasChecked" in box.dataset)) {
          box.dataset.wasChecked = box.checked ? "true" : "false";
        }
        box.checked = false;
      } else if (!on && "wasChecked" in box.dataset) {
        box.checked = box.dataset.wasChecked === "true";
        delete box.dataset.wasChecked;
      }
      box.disabled = on;

      // The hint says why the row is off. One of the three lines shows at a time.
      const account = box.querySelector("[data-network-account]");
      const markdownLine = box.querySelector("[data-network-markdown]");
      const photos = box.querySelector("[data-network-photos]");
      if (account) account.hidden = on;
      if (markdownLine) markdownLine.hidden = reason !== "markdown";
      if (photos) photos.hidden = reason !== "photos";
    });
  }

  /**
   * Shows the topic field only while the Threads row can take a post and is ticked.
   *
   * ⚠️ It reads `disabled` as well as `checked`: a row with no account is disabled, and
   * `applyBlueskyOnly` disables that row too. Thus that method runs first.
   * ⚠️ It never clears the field. A topic that the owner wrote stays after an untick.
   */
  applyTopic() {
    const box = this.networks.find((row) => row.value === this.topicFieldTarget.dataset.network);

    this.topicFieldTarget.hidden = !(box && !box.disabled && box.checked);
  }

  /**
   * @returns {boolean} True when any post of the thread holds a Markdown link.
   *
   * ⚠️ It is THREAD-LEVEL: a thread goes to a network as one unit, thus one link in one post
   * decides the whole draft. `SocialDraft#markdown?` reads it the same way.
   */
  get hasMarkdown() {
    return this.postTargets.some((post) => hasLinks(post.querySelector(BODY)?.value ?? ""));
  }

  /**
   * @returns {number} The most photos on one post of the thread, and that includes a photo whose
   *   upload is still out. It is THREAD-LEVEL, as `hasMarkdown` is, and
   *   `SocialDraft#most_photos` reads it the same way.
   */
  get mostPhotos() {
    return Math.max(0, ...this.postTargets.map((post) => post.querySelectorAll(PHOTO).length));
  }

  /**
   * @returns {boolean} True while the draft holds something to show. It follows the rule of
   *   `SocialDraft#posts`, which drops a block with nothing in it.
   */
  get canPreview() {
    return this.postTargets.some((post) => this.hasContent(post));
  }

  /**
   * Gives the Bluesky map to each post block, and makes it count again.
   *
   * ⚠️ Only the BLUESKY map goes out, because the count measures the Bluesky text. The server
   * measures the same string.
   * ⚠️ A value that this writes fires no `input` event, thus there is no loop back into validate.
   */
  pushMentions() {
    const json = this.mentionMap.blueskyJson;

    this.postTargets.forEach((post) => {
      if (post.dataset.socialPostBlueskyMentions === json) return;

      post.dataset.socialPostBlueskyMentions = json;
      this.postController(post)?.count();
    });
  }

  /**
   * @returns {boolean} True while the draft is one that the server will take.
   */
  get canPost() {
    // Every post needs words. ⚠️ This is stricter than the server, which drops a block with nothing
    // at all in it. A block that the owner added and left empty turns the button off instead, thus
    // the page never asks them to guess which post is the problem.
    const posts = this.postTargets;
    if (posts.some((post) => !post.querySelector(BODY)?.value?.trim())) return false;

    // ⚠️ It asks each post, and does not count again. The `social-post` controller writes its
    // count from the same `input` event, before the event reaches this form. A block that is
    // not connected yet holds nothing that can stop the draft.
    if (posts.some((post) => this.postController(post)?.blocked)) return false;

    if (!this.networks.some((box) => box.checked && !box.disabled)) return false;

    // ⚠️ The switch is on and the two fields name no moment, thus there is nothing to schedule.
    // A moment that has passed is not this case: it means "post now", as in `submitLabel`.
    return !(this.scheduleTarget.checked && !this.scheduledAt);
  }

  /**
   * @param {HTMLElement} post A post block.
   * @returns {object|null} The `social-post` controller of that block, or null before it connects.
   */
  postController(post) {
    return this.application.getControllerForElementAndIdentifier(post, "social-post");
  }

  /** @returns {HTMLElement[]} */
  get networks() {
    return [ ...this.element.querySelectorAll("wa-checkbox[name='networks[]']") ];
  }

  /**
   * Reads the draft when the owner opens the Preview tab.
   *
   * ⚠️ It reads `detail.name`, which `<wa-tab-group>` sets to the panel of the tab that it showed.
   * The event bubbles, thus a check of the name is what keeps the Write tab from asking.
   */
  tabShown(event) {
    if (event.detail?.name !== "preview") return;

    this.panel.load();
  }

  /** @returns {boolean} True while the Preview panel is the one on screen. */
  get previewActive() {
    return this.previewPanelTarget.hasAttribute("active");
  }

  /**
   * Makes the submit button busy.
   *
   * ⚠️ This is on the `submit` of the form, and not on the `click` of the button. A click comes
   * before the browser checks the fields, and on a form that is not complete the button would
   * then spin for all time.
   */
  markBusy() {
    this.submitTarget.loading = true;
  }

  /**
   * The moment that the two fields name, for the label of the button.
   * @returns {Date|null} The moment, or null when a field is empty or cannot be read.
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
