import { Controller } from "@hotwired/stimulus";
import { i18nTable, t } from "../lib/i18n";
import { hasLinks } from "../lib/markdown_links";
import { isBlueskyHandle, mentionKey, tokensOf } from "../lib/social_mentions";

// How long the words must be quiet before the rows are reconciled. ⚠️ A token churns while the
// owner types it — "@t", "@to", "@ton" — and a row for each of those would take the focus.
const MENTION_DEBOUNCE = 250;

// How long a change must be quiet before the open preview is read again. ⚠️ Only the mentions and
// the topic can change while that panel is on screen, thus this is rare and it can be short.
const PREVIEW_DEBOUNCE = 300;

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

    // The values of each mention, by key. ⚠️ A value stays here after its row goes away, thus a
    // token that the owner deletes and writes again gets its handles back.
    this.mentionValues = new Map();

    // ⚠️ It starts at false and not undefined, thus the first `validate()` of a draft with no
    // Markdown does nothing at all. Without that the else branch below would run at connect and
    // untick each row that the server rendered as ticked.
    this.markdownOn = false;

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
    // ⚠️ `wa-input` is in this list for the MENTION fields. Before the upgrade their `value` is
    // undefined, thus a read here would write over each handle that the server rendered with an
    // empty one. A page that renders again after a refusal holds those values.
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
   * Adds one empty post at the end of the thread, from the template.
   *
   * ⚠️ The content of a <template> is inert: the browser renders none of it and its fields are not
   * in the form. Only this clone puts a block in the document.
   */
  addPost(event) {
    event.preventDefault();
    if (this.postTargets.length >= this.maxPostsValue) return;

    // ⚠️ The map goes on the block BEFORE it joins the document, thus the new block counts
    // correctly at its own `connect()`. The copy in the template is the one that the server
    // rendered, and the owner can have edited a handle after that.
    const added = this.templateTarget.content.cloneNode(true);
    const block = added.querySelector("[data-social-target='post']");
    if (block) block.dataset.socialPostBlueskyMentions = this.blueskyMentionsJson;

    this.postsTarget.appendChild(added);
    this.renumber();
    this.validate();

    // The words are the point of a new post, thus the caret goes there.
    this.postTargets[this.postTargets.length - 1]?.querySelector("wa-textarea")?.focus();
  }

  /**
   * Removes the post that holds the control that was pressed.
   *
   * ⚠️ **A post that holds something asks first.** A block is as much as 300 characters and a link,
   * and nothing here can put it back: there is no undo, and the browser keeps no copy. A block that
   * is still empty goes at once, because a question about nothing is only noise.
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
   * ⚠️ It runs at `wa-hide`, thus Cancel, the Escape key, and the close button of the header all
   * reach it. Without this a post that the owner kept would stay in this reference.
   *
   * ⚠️ **It is `wa-hide` and NOT `wa-after-hide`.** The second one waits for the close animation to
   * be complete, and a measurement in a browser gave a `wa-hide` with no `wa-after-hide` after it.
   * Thus a handler on that event can never run at all.
   */
  clearRemoval() {
    this.pendingRemoval = null;
  }

  /**
   * Takes one post out of the thread.
   * @param {HTMLElement} post
   */
  dropPost(post) {
    post.remove();
    this.renumber();
    this.validate();
  }

  /**
   * @param {HTMLElement} post
   * @returns {boolean} True when that post holds words or a link.
   */
  hasContent(post) {
    return !!(post.querySelector("wa-textarea")?.value?.trim() ||
              post.querySelector("wa-input[type='url']")?.value?.trim());
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
   * ⚠️ It runs from `input` and `change` on the **form**, thus one action covers each field of
   * each post and each network. A field of a post belongs to the `social-post` controller, and
   * this one reads the DOM in place of reaching into it.
   */
  validate() {
    // ⚠️ The order matters. `pushMentions` recounts each post AT ONCE, and `canPost` below reads
    // the count line that the recount wrote. A push that arrived later would leave the button on
    // for a draft that is already past the limit.
    this.readMentionRows();
    this.pushMentions();
    this.scheduleMentionScan();
    // ⚠️ It runs BEFORE `canPost`, which reads the ticks that this method can change.
    this.applyMarkdown();
    // ⚠️ And AFTER it, because a Markdown link unticks and disables the Threads row.
    this.applyTopic();

    this.submitTarget.disabled = !this.canPost;
    // ⚠️ This is NOT `canPost`. A draft that is past the limit, or that ticks no network, is exactly
    // the draft that the owner wants to look at.
    this.previewTabTarget.disabled = !this.canPreview;

    // ⚠️ A network goes away AT ONCE and it needs no request: the answer holds each connected
    // network, and this hides the rows of the ones that the owner unticked. The refresh below is
    // for the mentions and the topic, which change the TEXT and which only the server can write.
    this.filterPreview();
    if (this.previewActive) this.schedulePreviewRefresh();

    this.relabel();
  }

  /**
   * Turns the rows of Mastodon and Threads off while the draft holds a Markdown link.
   *
   * ⚠️ **Only Bluesky has rich text.** There a link is a facet: the words carry the address, and
   * the URL uses none of the 300 characters. The other two post plain words, thus the same draft
   * would reach a reader as `[my post](https://…)`. `Admin::SocialController#markdown_network_error`
   * refuses such a request as well, because a row that a browser cannot tick a hand-written request
   * can.
   *
   * ⚠️ **It does nothing while the state has not changed**, and that is not only an optimisation:
   * this runs at each keystroke, thus a restore at every one of them would put back a tick that the
   * owner had just taken off.
   *
   * ⚠️ It reads the `markdownNetwork` targets, which the view puts on the CONNECTED rows of those
   * two networks alone. A row with no account is disabled for its own reason, and it must never
   * come back on.
   */
  applyMarkdown() {
    const on = this.hasMarkdown;
    if (on === this.markdownOn) return;

    this.markdownOn = on;
    this.markdownNetworkTargets.forEach((box) => {
      if (on) {
        // ⚠️ It keeps the tick that the owner had, thus a link that they write and then remove
        // gives the draft its networks back.
        box.dataset.wasChecked = box.checked ? "true" : "false";
        box.checked = false;
      } else if ("wasChecked" in box.dataset) {
        box.checked = box.dataset.wasChecked === "true";
      }
      box.disabled = on;

      // The hint says why the row is off. One of the two lines shows at a time.
      const account = box.querySelector("[data-network-account]");
      const reason = box.querySelector("[data-network-markdown]");
      if (account) account.hidden = on;
      if (reason) reason.hidden = !on;
    });
  }

  /**
   * Shows the topic field only while the Threads row can take a post and is ticked.
   *
   * ⚠️ **It reads `disabled` as well as `checked`.** A row with no account is disabled, and a
   * Markdown link disables that row too, thus one rule covers both and `applyMarkdown` above runs
   * first.
   *
   * ⚠️ It never clears the field. A topic that the owner wrote survives an untick and a tick
   * again, and the action reads the value only while the row is ticked.
   */
  applyTopic() {
    const box = this.networks.find((row) => row.value === this.topicFieldTarget.dataset.network);

    this.topicFieldTarget.hidden = !(box && !box.disabled && box.checked);
  }

  /**
   * @returns {boolean} True when any post of the thread holds a Markdown link.
   *
   * ⚠️ It is THREAD-LEVEL: a thread goes to a network as one unit, thus one link in one post
   * decides the whole draft. `Admin::SocialController#markdown?` reads it the same way.
   */
  get hasMarkdown() {
    return this.postTargets.some((post) => hasLinks(post.querySelector("wa-textarea")?.value ?? ""));
  }

  /**
   * @returns {boolean} True while the draft holds something to show.
   *
   * ⚠️ It reads text OR link, which is the rule that `Admin::SocialController#posts` follows: that
   * method drops a block with nothing at all in it. Thus an empty draft gives no post, and a dialog
   * that opens to say "nothing yet" is worse than a button that is off.
   */
  get canPreview() {
    return this.postTargets.some((post) => this.hasContent(post));
  }

  /**
   * Reads each row of the mention section into the Map.
   *
   * ⚠️ It runs BEFORE the scan, thus a row that the scan is about to remove has its values kept.
   */
  readMentionRows() {
    this.mentionTargets.forEach((row) => {
      const token = row.querySelector("[data-mention-token]")?.value ?? "";
      if (!token) return;

      const handles = {};
      row.querySelectorAll("[data-mention-network]").forEach((field) => {
        handles[field.dataset.mentionNetwork] = field.value ?? "";
      });

      this.mentionValues.set(mentionKey(token), { token, handles });
    });
  }

  /**
   * Gives the Bluesky map to each post block, and makes it count again.
   *
   * ⚠️ Only the BLUESKY map goes out, because the count measures the Bluesky text: that network
   * has the shortest limit and the longest handles. The server measures the same string.
   *
   * ⚠️ A value that this writes fires no `input` event, thus there is no loop back into validate.
   */
  pushMentions() {
    const json = this.blueskyMentionsJson;

    this.postTargets.forEach((post) => {
      if (post.dataset.socialPostBlueskyMentions === json) return;

      post.dataset.socialPostBlueskyMentions = json;
      this.application.getControllerForElementAndIdentifier(post, "social-post")?.count();
    });
  }

  /** @returns {string} The Bluesky field of each mention, by key, as JSON. */
  get blueskyMentionsJson() {
    const map = {};
    this.mentionValues.forEach((entry, key) => {
      const value = entry.handles?.bluesky?.trim();
      if (value) map[key] = value;
    });

    return JSON.stringify(map);
  }

  /**
   * Waits for the typing to stop, then reconciles the rows.
   */
  scheduleMentionScan() {
    clearTimeout(this.mentionTimer);
    this.mentionTimer = setTimeout(() => this.scanMentions(), MENTION_DEBOUNCE);
  }

  /**
   * Makes the rows of the section match the tokens of the draft.
   *
   * ⚠️ It RECONCILES and it never renders the section again. A rebuild would take the focus and
   * lose each value at every keystroke.
   */
  scanMentions() {
    this.readMentionRows();

    // The tokens of the whole draft. ⚠️ The map is thread-level, thus a token in post 1 and in
    // post 3 is one row. The first spelling wins, and that is the one that a network with no
    // handle will show.
    const wanted = new Map();
    this.postTargets.forEach((post) => {
      const words = post.querySelector("wa-textarea")?.value ?? "";
      tokensOf(words).forEach((token) => {
        const key = mentionKey(token);
        if (!wanted.has(key)) wanted.set(key, token);
      });
    });

    // ⚠️ A row that goes away keeps its values in the Map above, thus a token that comes back gets
    // them again.
    this.mentionTargets.forEach((row) => {
      if (!wanted.has(this.keyOfRow(row))) row.remove();
    });

    wanted.forEach((token, key) => {
      if (this.rowFor(key)) return;

      this.mentionRowsTarget.appendChild(this.buildMentionRow(token, key));
    });

    // ⚠️ A node that moves loses the focus, thus the rows are not put in order while the owner is
    // typing in one of them. The next scan does it.
    if (!this.mentionRowsTarget.contains(document.activeElement)) {
      wanted.forEach((_token, key) => {
        const row = this.rowFor(key);
        if (row) this.mentionRowsTarget.appendChild(row);
      });
    }

    this.mentionsTarget.hidden = wanted.size === 0 || !this.hasMentionFields;
    this.pushMentions();
    this.submitTarget.disabled = !this.canPost;
  }

  /**
   * Makes one row from the template, with the values that the owner already gave.
   * @param {string} token
   * @param {string} key
   * @returns {HTMLElement}
   */
  buildMentionRow(token, key) {
    const row = this.mentionTemplateTarget.content.cloneNode(true)
      .querySelector("[data-social-target='mention']");
    const stored = this.mentionValues.get(key);

    row.querySelector("[data-mention-token]").value = token;
    const label = row.querySelector("[data-mention-label]");
    if (label) label.textContent = token;

    row.querySelectorAll("[data-mention-network]").forEach((field) => {
      const network = field.dataset.mentionNetwork;
      field.value = stored?.handles?.[network] || this.seedFor(token, network);
    });

    return row;
  }

  /**
   * The value to put in a field of a new row.
   *
   * ⚠️ A token that is ALREADY a handle seeds its own field, thus "@tony.bsky.social" in the body
   * still works at Bluesky with no typing. **Nothing seeds Threads**: a bare "@name" is exactly the
   * ambiguous case, and a guess there is what tags a stranger.
   * @param {string} token
   * @param {string} network
   * @returns {string}
   */
  seedFor(token, network) {
    const bare = token.replace(/^@/, "");

    if (network === "bluesky") return isBlueskyHandle(bare) ? bare : "";
    if (network === "mastodon") return bare.includes("@") ? bare : "";

    return "";
  }

  /**
   * ⚠️ With no account connected there is no field to fill, thus the section stays away whatever
   * the words hold. The server still removes the "@" of each token, thus such a draft posts a name
   * and it can never tag a stranger.
   * @returns {boolean}
   */
  get hasMentionFields() {
    return !!this.mentionTemplateTarget.content.querySelector("[data-mention-network]");
  }

  /** @param {HTMLElement} row @returns {string} */
  keyOfRow(row) {
    return mentionKey(row.querySelector("[data-mention-token]")?.value ?? "");
  }

  /** @param {string} key @returns {HTMLElement|undefined} */
  rowFor(key) {
    return this.mentionTargets.find((row) => this.keyOfRow(row) === key);
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
   * Reads the draft when the owner opens the Preview tab.
   *
   * ⚠️ It reads `detail.name`, which `<wa-tab-group>` sets to the panel of the tab that it showed.
   * The event bubbles, thus a check of the name is what keeps the Write tab from asking.
   */
  tabShown(event) {
    if (event.detail?.name !== "preview") return;

    this.preview();
  }

  /** @returns {boolean} True while the Preview panel is the one on screen. */
  get previewActive() {
    return this.previewPanelTarget.hasAttribute("active");
  }

  /**
   * Reads the draft again after the owner changes something while the preview is open.
   *
   * ⚠️ The words of a post cannot change here: they are in the Write panel. This is for the
   * mentions and the topic, which the server writes into the text.
   */
  schedulePreviewRefresh() {
    clearTimeout(this.previewTimer);
    this.previewTimer = setTimeout(() => this.preview(), PREVIEW_DEBOUNCE);
  }

  /**
   * Hides the row of each network that the owner did not tick.
   *
   * ⚠️ The action answers with every CONNECTED network, and the ticks decide what a post goes to.
   * Thus this filter is what makes the panel show the draft as it will be sent, and it needs no
   * request of its own.
   */
  filterPreview() {
    const wanted = this.networks.filter((box) => box.checked && !box.disabled)
                       .map((box) => box.value);
    const groups = [ ...this.previewBodyTarget.querySelectorAll("[data-preview-network]") ];
    groups.forEach((group) => {
      group.hidden = !wanted.includes(group.dataset.previewNetwork);
    });

    // ⚠️ The line shows only when the panel HOLDS a group and none of them is wanted. An empty
    // draft has its own message, and the two must not both appear.
    const empty = groups.length > 0 && groups.every((group) => group.hidden);
    this.previewEmptyTarget.textContent = empty ? t(this.words, "preview_no_network") : "";
    this.previewEmptyTarget.hidden = !empty;
  }

  /**
   * Fills the preview panel with the draft as each network will receive it.
   *
   * ⚠️ The markup opens the dialog, thus this only fills it. It reads the draft AT THE CLICK, thus
   * it needs no debounce and no `input` action: that is the difference from the link preview,
   * which follows the typing.
   *
   * ⚠️ `FormData(this.element)` sends every field that a real submit sends, thus the request needs
   * no list of the fields and cannot go out of date when one is added.
   *
   * ⚠️ **It sends the CSRF token in a header of its own.** The admin does not skip the forgery
   * protection, thus this POST needs that token. The body of the form carries one as well, and the
   * header does not depend on it: neither the test environment nor a page that a spec renders has
   * a token at all, thus no spec here can prove that the body alone would pass.
   */
  async preview() {
    this.previewBodyTarget.replaceChildren();
    this.previewEmptyTarget.hidden = true;
    this.previewSpinnerTarget.hidden = false;

    // ⚠️ A second click while one request is out must not let the older answer write. It is the
    // rule that `social-post#preview` follows for the card of a link.
    this.previewSeq = (this.previewSeq ?? 0) + 1;
    const seq = this.previewSeq;

    try {
      const response = await fetch(this.previewUrlValue, {
        method: "POST",
        headers: { Accept: "application/json", ...this.csrfHeader },
        body: new FormData(this.element),
      });
      if (seq !== this.previewSeq) return;

      if (!response.ok) return this.showPreviewMessage("preview_failed");
      this.showPreview(await response.json());
    } catch {
      if (seq === this.previewSeq) this.showPreviewMessage("preview_failed");
    } finally {
      if (seq === this.previewSeq) this.previewSpinnerTarget.hidden = true;
    }
  }

  /**
   * The CSRF token of the page, as a header.
   *
   * ⚠️ `csrf_meta_tags` renders nothing where the forgery protection is off, which is the test
   * environment. Thus this gives an empty object there and the header is absent, and the request
   * still passes.
   * @returns {object}
   */
  get csrfHeader() {
    const token = document.querySelector("meta[name='csrf-token']")?.content;

    return token ? { "X-CSRF-Token": token } : {};
  }

  /**
   * Writes one group for each post, and one row for each network below it.
   * @param {object} draft The answer of the preview action.
   */
  showPreview(draft) {
    // ⚠️ The Preview button is off for a draft with nothing in it, thus this is a fallback and not
    // the ordinary path. It stays because a dialog that opens and stays blank says nothing at all.
    const networks = draft?.networks ?? [];
    if (networks.length === 0) return this.showPreviewMessage("preview_empty");

    const body = this.previewBodyTarget;
    body.replaceChildren();

    networks.forEach((network) => {
      const group = this.cloneTemplate(this.previewGroupTemplateTarget, ".social-preview__group");

      // ⚠️ `filterPreview` reads this to hide the group of a network that the owner unticks.
      group.dataset.previewNetwork = network.key;
      group.querySelector("[data-preview-name]").textContent = network.name;

      const cards = group.querySelector("[data-preview-cards]");
      network.posts.forEach((post) => cards.appendChild(this.previewCard(post)));
      body.appendChild(group);
    });

    // ⚠️ The answer holds each connected network, thus the new groups need the filter at once.
    this.filterPreview();
  }

  /**
   * One card: one post of one network.
   * @param {object} post
   * @returns {HTMLElement}
   */
  previewCard(post) {
    const card = this.cloneTemplate(this.previewRowTemplateTarget, ".social-preview__card");
    const count = card.querySelector("[data-preview-count]");

    // The place of the post in its thread, as "1/2". A draft of one post gets none: the action
    // sends no label for it.
    const label = card.querySelector("[data-preview-label]");
    if (post.label) {
      label.textContent = post.label;
      label.hidden = false;
    }

    count.textContent = `${post.length} / ${post.limit}`;
    count.classList.toggle("social-preview__count--over", post.over);
    card.querySelector("[data-preview-text]").replaceChildren(...this.textNodes(post.segments));

    // The topic, for the one network that takes one.
    const topic = card.querySelector("[data-preview-topic]");
    if (post.topic) {
      topic.textContent = post.topic;
      topic.hidden = false;
    }

    // The website card that Bluesky renders for the link. ⚠️ Only that network carries one: this
    // app builds its embed, and Meta renders its own attachment for Threads.
    this.fillLinkCard(card, post.card);

    // The note says where the link went, for a network whose card this app does not draw.
    const note = card.querySelector("[data-preview-note]");
    if (post.note) {
      note.textContent = post.note;
      note.hidden = false;
    }

    return card;
  }

  /**
   * Fills the website card of a post, or leaves it away.
   *
   * ⚠️ It is the same shape that `social-post#showPreview` writes below the link field, because
   * `Admin::SocialController#card_json` answers both. Thus the two cannot describe one page
   * differently.
   * @param {HTMLElement} card The preview card of the post.
   * @param {object|null} link The website card, from the action.
   */
  fillLinkCard(card, link) {
    const element = card.querySelector("[data-preview-card]");
    if (!link) return;

    card.querySelector("[data-preview-card-host]").textContent = link.host ?? "";
    card.querySelector("[data-preview-card-title]").textContent = link.title ?? "";
    card.querySelector("[data-preview-card-description]").textContent = link.description ?? "";

    // ⚠️ `withMedia` follows the picture, for the reason that the markup gives.
    const picture = card.querySelector("[data-preview-card-image]");
    picture.hidden = !link.image_path;
    element.withMedia = !!link.image_path;
    if (link.image_path) picture.src = link.image_path;

    // Which of the two cards Bluesky will render, which the owner cannot know without it.
    const kind = card.querySelector("[data-preview-card-kind]");
    kind.textContent = t(this.words, link.standard_site ? "standard_site" : "open_graph");
    kind.variant = link.standard_site ? "success" : "neutral";

    element.hidden = false;
  }

  /**
   * The text of one network, in pieces, with each link as a link.
   *
   * ⚠️ **A Markdown link shows its WORDS and never its address**, thus the owner cannot check one
   * without this: an `<a>` is the only thing that says where those words point. A bare URL that
   * the owner pasted becomes a link at each of the three networks, and it is a link here as well.
   *
   * ⚠️ It writes each piece with `textContent` and `href`, and never with HTML. The action gives
   * a `url` that is http or https and nothing else, thus no draft can make a `javascript:` link.
   * @param {Array<{text: string, url?: string}>} segments
   * @returns {Node[]}
   */
  textNodes(segments) {
    return (segments ?? []).map((segment) => {
      if (!segment.url) return document.createTextNode(segment.text);

      const link = document.createElement("a");
      link.href = segment.url;
      link.textContent = segment.text;
      // ⚠️ The dialog holds the draft. A link that replaced this page would lose it.
      link.target = "_blank";
      link.rel = "noopener noreferrer";

      return link;
    });
  }

  /**
   * Writes one line in the dialog. ⚠️ A dialog that opens and stays empty says nothing at all.
   * @param {string} key A key below `admin.js.social`.
   */
  showPreviewMessage(key) {
    const line = document.createElement("p");
    line.textContent = t(this.words, key);
    this.previewBodyTarget.replaceChildren(line);
  }

  /**
   * @param {HTMLTemplateElement} template
   * @param {string} selector
   * @returns {HTMLElement}
   */
  cloneTemplate(template, selector) {
    return template.content.cloneNode(true).querySelector(selector);
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
