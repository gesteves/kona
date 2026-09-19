import { Controller } from "@hotwired/stimulus";
import { i18nTable, t } from "../lib/i18n";
import { render } from "../lib/markdown_links";
import { blueskyText } from "../lib/social_mentions";
import { applyLengthRules } from "../lib/typography";
import { toast } from "../lib/toast";
import { csrfHeader } from "../lib/csrf";

// How long the link field must be quiet before this reads the card. Each preview is one request of
// this app, which then reads the page of another host.
const PREVIEW_DEBOUNCE = 600;

// The three states of the link of a post, and each one shows one control: the button of the
// toolbar, the field, or the card. ⚠️ The X on the card is the one way back to IDLE.
const IDLE = "idle";
const EDITING = "editing";
const ATTACHED = "attached";

// The two states of the photos of a post: nothing below the toolbar, or the picker with the
// tiles below it. ⚠️ The picker stays OPEN while the post holds a photo, thus the owner can add
// more. Its X shows while it is empty, and that X is the way back to IDLE.
const OPEN = "open";

// One photo tile of the post.
const PHOTO = "[data-social-post-target='photo']";

/**
 * One post of the thread: its character count, the preview of its link, and its photos.
 *
 * ⚠️ Each block is its own controller, and the outer `social` controller never reaches into it.
 * One controller for each block is what keeps the count and the preview of one post away from the
 * others; a flat list of targets on the outer controller would need an index at every call.
 *
 * ⚠️ **The link and the photos are ONE state machine**, and that is why the photos are here and
 * not in a controller of their own: a post takes photos OR a link, because Bluesky renders one
 * embed. Each button of the toolbar is disabled while the other attachment has a value.
 */
export default class extends Controller {
  static targets = [
    "body", "count", "countText", "ring", "link", "spinner", "preview", "previewImage",
    "previewHost", "previewTitle", "previewDescription", "previewKind", "linkButton", "countNotice",
    "photoButton", "fileInput", "photos", "tiles", "pickerClose", "photoTemplate", "photo",
  ];
  static values = {
    limit: Number, warnAt: Number, previewUrl: String,
    uploadUrl: String, maxPhotos: Number, altLimit: Number,
  };

  connect() {
    // ⚠️ The words come from the locale file, through the `data-admin-i18n` attribute.
    this.words = i18nTable(this.element);
    this.linkState = IDLE;
    this.photoState = IDLE;
    // The upload of each tile that is still out, by tile. `disconnect()` and a remove abort it.
    this.uploads = new Map();
    // ⚠️ It waits for the definitions: `value` is undefined on these components until the browser
    // upgrades them. A Turbo restoration visit, and a page that renders again after a refusal, both
    // hold values with no controller state.
    Promise.all(
      ["wa-textarea", "wa-input", "wa-button", "wa-file-input"].map((tag) => customElements.whenDefined(tag))
    ).then(() => {
      // ⚠️ A snapshot of Turbo can hold a tile whose upload never finished: it has no id, and
      // nothing can finish it now. It goes, before the state below reads the count of the tiles.
      this.dropUnfinishedPhotos();
      // ⚠️ Each state comes from the MARKUP, thus it is the state that the server already
      // rendered and nothing moves. `preview()` below promotes the link to ATTACHED when the page
      // reads, and the picker is open for a post that holds a photo.
      this.linkState = this.linkTarget.value?.trim() ? EDITING : IDLE;
      this.photoState = this.photoCount > 0 || !this.photosTarget.hidden ? OPEN : IDLE;
      this.renderAttachmentState();
      this.photoTargets.forEach((tile) => this.countAltOf(tile));
      this.count();
      this.preview();
    });
  }

  /**
   * Stops the preview timer, the request that is out, and each upload that is out.
   *
   * ⚠️ A Turbo visit disconnects the controller, and an answer that lands after it would write
   * into a page that is gone. The object URL of each tile goes as well: the browser keeps the
   * bytes of one until the page revokes it.
   */
  disconnect() {
    clearTimeout(this.previewTimer);
    this.previewSeq = (this.previewSeq ?? 0) + 1;
    this.previewAborter?.abort();
    this.uploads.forEach((aborter) => aborter.abort());
    this.uploads.clear();
    this.photoTargets.forEach((tile) => this.revokePreview(tile));
  }

  /**
   * Opens the link field: the button of the toolbar asks for a link, and Edit in the footer of the
   * card takes the owner back to the one that the post carries.
   *
   * ⚠️ The button of the toolbar is disabled by then. There is one link for each post, thus "add a
   * link" has no meaning while one is being written or is already attached.
   */
  showLink() {
    this.setLinkState(EDITING);
    this.linkTarget.focus();
  }

  /**
   * Reads the card at once, when the field loses the focus.
   *
   * ⚠️ **This is what closes the round trip of the Edit control.** That control opens the field
   * with a URL already in it, thus a person who changes nothing fires no `input` and no `change`,
   * and the card would never come back. It is nearly always a Redis hit: `OpenGraph` caches each
   * page for 15 minutes.
   *
   * ⚠️ It runs for the X of the field as well, because a click blurs before it fires. That read
   * takes the next sequence number and `removeLink` takes the one after it, thus the answer of the
   * blur cannot draw the card of a link that the click removed.
   */
  commitLink() {
    clearTimeout(this.previewTimer);
    this.preview();
  }

  /**
   * Takes the link off the post and goes back to the button of the toolbar.
   *
   * ⚠️ **Three controls call this**: the X in the corner of the card, the X inside the field, and
   * the Escape key in that field. EDITING has its own way out because the card cannot give it one:
   * a field that the owner opened and left empty never becomes a card.
   *
   * ⚠️ It clears the value and does not only close the field. The field IS the link, thus a field
   * that closes with a value in it would still send that value with the form.
   */
  removeLink() {
    this.linkTarget.value = "";
    this.setLinkState(IDLE);
    // ⚠️ A value that code writes fires no event, and the form validates on `input`. Thus the
    // submit button would stay as it was for a draft that this click emptied. The handler of that
    // event also stops the timer, the spinner, and the request that is still out.
    this.linkTarget.dispatchEvent(new Event("input", { bubbles: true }));
    this.linkButtonTarget.focus();
  }

  /**
   * Shows the one control of each state, and disables each button of the toolbar that can do
   * nothing now.
   *
   * ⚠️ The link field and the card take turns, and each one carries an X that goes back to IDLE.
   * The picker works the same way: the photo button opens it, and its X closes it while it holds
   * no photo.
   *
   * ⚠️ **A post takes photos OR a link.** Thus each button of the toolbar is off while the other
   * attachment is open, and off outside its own IDLE state. The server renders the same states,
   * thus a page that renders again after a refusal shows them before this runs.
   *
   * ⚠️ **A button is DISABLED and never hidden.** It is a form control and it is taller than the
   * count beside it, thus a button that goes away takes the height of the toolbar with it and the
   * count moves up at the click that opened the field.
   *
   * ⚠️ The file input is disabled at the most photos, and the X of the picker shows only while
   * the picker holds none: a picker that closes with tiles in it would still send them.
   */
  renderAttachmentState() {
    const photos = this.photoCount;
    const open = this.photoState === OPEN;

    this.linkButtonTarget.disabled = this.linkState !== IDLE || open;
    this.photoButtonTarget.disabled = this.linkState !== IDLE || open;
    this.photosTarget.hidden = !open;
    this.fileInputTarget.disabled = photos >= this.maxPhotosValue;
    this.pickerCloseTarget.hidden = photos > 0;
    this.linkTarget.hidden = this.linkState !== EDITING;
    this.previewTarget.hidden = this.linkState !== ATTACHED;
  }

  /**
   * @param {string} state
   */
  setLinkState(state) {
    this.linkState = state;
    this.renderAttachmentState();
  }

  /** @returns {number} The tiles of the post, and that includes one whose upload is out. */
  get photoCount() {
    return this.photoTargets.length;
  }

  /**
   * Opens the picker below the toolbar, as `showLink` opens the link field.
   */
  showPhotos(event) {
    event.preventDefault();
    this.photoState = OPEN;
    this.changed();
    this.fileInputTarget.focus();
  }

  /**
   * Closes an empty picker and goes back to the button of the toolbar.
   *
   * ⚠️ It does nothing while the picker holds a tile. The X is hidden then, and the Escape key
   * must not take a photo off the post: the X of each tile is the way back.
   */
  hidePhotos(event) {
    if (this.photoCount > 0) return;

    event.preventDefault();
    this.photoState = IDLE;
    this.changed();
    this.photoButtonTarget.focus();
  }

  /**
   * Uploads each file that the owner picked, up to the free slots of the post.
   *
   * ⚠️ It empties the input after the read, thus the component draws no list of its own and the
   * tiles are the one list. It also lets the same file be picked again after a remove: an input
   * fires no `change` for a value that did not change.
   */
  filesPicked() {
    const files = [ ...(this.fileInputTarget.files ?? []) ];
    if (files.length === 0) return;
    this.fileInputTarget.files = [];

    const room = Math.max(0, this.maxPhotosValue - this.photoCount);
    if (files.length > room) {
      toast(t(this.words, "too_many_photos", { limit: this.maxPhotosValue }), "warning");
    }
    files.slice(0, room).forEach((file) => this.upload(file));
  }

  /**
   * Adds a tile for one file and uploads it.
   *
   * ⚠️ The tile is on the page from the first moment, with the file itself as its picture: the CSP
   * of the admin permits `blob:` in `img-src` for this. Its id stays empty until the server
   * answers, and `social#canPost` keeps the submit button off while a tile is in that state.
   *
   * ⚠️ A refusal takes the tile away and says why in a toast. The server names the reason for a
   * file that is not a photo or that is too large, and the toast shows those words.
   * @param {File} file
   */
  async upload(file) {
    const tile = this.buildTile(file);
    this.tilesTarget.appendChild(tile);
    this.changed();

    const aborter = new AbortController();
    this.uploads.set(tile, aborter);
    const body = new FormData();
    body.append("photo", file, file.name);

    try {
      const response = await fetch(this.uploadUrlValue, {
        method: "POST",
        headers: { Accept: "application/json", ...csrfHeader() },
        body,
        signal: aborter.signal,
      });
      const answer = await response.json().catch(() => ({}));

      if (!response.ok) {
        this.dropTile(tile);
        toast(answer.error || t(this.words, "upload_failed"), "danger");
        return;
      }
      this.fillTile(tile, answer);
    } catch {
      // A remove or a Turbo visit aborted it, and the tile is already gone.
      if (aborter.signal.aborted) return;

      this.dropTile(tile);
      toast(t(this.words, "upload_unreachable"), "danger");
    } finally {
      this.uploads.delete(tile);
      if (this.element.isConnected) this.changed();
    }
  }

  /**
   * One tile in its uploading state, from the template.
   * @param {File} file
   * @returns {HTMLElement}
   */
  buildTile(file) {
    const tile = this.photoTemplateTarget.content.cloneNode(true).querySelector(PHOTO);
    tile.classList.add("social-photo--uploading");
    tile.querySelector("[data-photo-spinner]").hidden = false;

    const image = tile.querySelector("[data-photo-image]");
    image.src = URL.createObjectURL(file);
    image.dataset.objectUrl = image.src;

    return tile;
  }

  /**
   * Writes the answer of the server into the tile.
   *
   * ⚠️ The picture changes to the path of our own store only after that copy has loaded, thus the
   * tile never shows an empty box between the two. The object URL goes at that moment.
   * @param {HTMLElement} tile
   * @param {object} answer `{ id, path }`
   */
  fillTile(tile, answer) {
    tile.querySelector("[data-photo-id]").value = answer.id ?? "";
    tile.classList.remove("social-photo--uploading");
    tile.querySelector("[data-photo-spinner]").hidden = true;

    const image = tile.querySelector("[data-photo-image]");
    const stored = new Image();
    const swap = () => {
      if (!tile.isConnected) return;
      image.src = answer.path;
      this.revokePreview(tile);
    };
    stored.addEventListener("load", swap);
    stored.addEventListener("error", swap);
    stored.src = answer.path;
  }

  /**
   * Takes one photo off the post. It asks nothing: a photo is quick to add again, and the alt
   * text of one is short.
   */
  removePhoto(event) {
    event.preventDefault();
    const tile = event.target.closest(PHOTO);
    if (!tile) return;

    this.dropTile(tile);
    this.changed();
    // The picker stays open, thus the focus goes to it and not to the button of the toolbar.
    this.fileInputTarget.focus();
  }

  /**
   * Removes a tile, and stops its upload when one is out.
   * @param {HTMLElement} tile
   */
  dropTile(tile) {
    this.uploads.get(tile)?.abort();
    this.uploads.delete(tile);
    this.revokePreview(tile);
    tile.remove();
  }

  /**
   * Removes each tile whose upload never finished. ⚠️ It runs at connect, for a snapshot of Turbo
   * that holds such a tile.
   */
  dropUnfinishedPhotos() {
    const unfinished = this.photoTargets.filter((tile) => !tile.querySelector("[data-photo-id]")?.value);
    unfinished.forEach((tile) => this.dropTile(tile));
    if (unfinished.length > 0) this.changed();
  }

  /**
   * Gives the browser back the bytes of the picture of a tile.
   * @param {HTMLElement} tile
   */
  revokePreview(tile) {
    const image = tile.querySelector("[data-photo-image]");
    if (!image?.dataset.objectUrl) return;

    URL.revokeObjectURL(image.dataset.objectUrl);
    delete image.dataset.objectUrl;
  }

  /**
   * Renders the toolbar again and tells the form.
   *
   * ⚠️ A tile that code adds or removes fires no event, and the form validates on `input`. Thus
   * without this the submit button and the "Post to" rows would keep the state of the draft
   * before the change. It is the rule of `removeLink`.
   */
  changed() {
    this.renderAttachmentState();
    this.element.dispatchEvent(new Event("input", { bubbles: true }));
  }

  /**
   * Picks up the tile that owns the grip.
   *
   * ⚠️ Firefox starts no drag at all with no data on the transfer, thus the empty string is
   * necessary and not decoration. It is the rule of `social#dragStart`.
   */
  dragStartPhoto(event) {
    this.draggedPhoto = event.target.closest(PHOTO);
    if (!this.draggedPhoto) return;

    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", "");
    this.draggedPhoto.classList.add("social-photo--dragging");
  }

  /**
   * Moves the tile that the pointer holds to where the pointer is.
   *
   * ⚠️ It moves the tile itself and it never rewrites a field. The names carry no index, thus
   * **the order of the tiles in the document IS the order of the photos**, and moving one is the
   * whole change.
   */
  dragOverPhoto(event) {
    if (!this.draggedPhoto) return;

    // ⚠️ Without this the browser refuses the drop and the tile springs back.
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";

    const slot = this.photoSlot(event.clientX, event.clientY);
    if (!slot || slot.tile === this.draggedPhoto) return;

    slot.before ? this.tilesTarget.insertBefore(this.draggedPhoto, slot.tile)
                : this.tilesTarget.insertBefore(this.draggedPhoto, slot.tile.nextSibling);
  }

  /**
   * `dragover` already moved the tile, thus this only stops the browser from its own default,
   * which is to open the dragged data as a URL.
   */
  dropPhoto(event) {
    event.preventDefault();
  }

  dragEndPhoto() {
    this.draggedPhoto?.classList.remove("social-photo--dragging");
    this.draggedPhoto = null;
  }

  /**
   * The tile to insert before, and which side of it the point is on.
   *
   * The tiles are a column, thus the test is the one of the posts: the first tile whose middle
   * is below the point is the one to insert before, and with none the tile goes last.
   * @param {number} _x
   * @param {number} y
   * @returns {{ tile: HTMLElement, before: boolean }|null} Null with no other tile.
   */
  photoSlot(_x, y) {
    const others = this.photoTargets.filter((tile) => tile !== this.draggedPhoto);
    if (others.length === 0) return null;

    const below = others.find((tile) => {
      const box = tile.getBoundingClientRect();
      return y < box.top + box.height / 2;
    });

    return below ? { tile: below, before: true } : { tile: others[others.length - 1], before: false };
  }

  /**
   * Moves a tile with the arrow keys.
   *
   * ⚠️ A drag needs a pointer, and this page must work without one. The grip is a button and it
   * takes the focus, thus the arrow keys are the way in. Up goes earlier and Down goes later, as
   * for a post; Left and Right do the same.
   */
  movePhotoByKey(event) {
    const earlier = event.key === "ArrowLeft" || event.key === "ArrowUp";
    const later = event.key === "ArrowRight" || event.key === "ArrowDown";
    if (!earlier && !later) return;

    event.preventDefault();
    const tile = event.target.closest(PHOTO);
    const tiles = this.photoTargets;
    const to = tiles.indexOf(tile) + (earlier ? -1 : 1);
    if (to < 0 || to >= tiles.length) return;

    earlier ? this.tilesTarget.insertBefore(tile, tiles[to])
            : this.tilesTarget.insertBefore(tiles[to], tile);

    // ⚠️ A node that moves loses the focus, thus the next arrow key would go to the document.
    tile.querySelector(".social-photo__grip")?.focus();
  }

  /**
   * Counts the alt text of the tile that holds the field.
   */
  countAlt(event) {
    const tile = event.target.closest(PHOTO);
    if (tile) this.countAltOf(tile);
  }

  /**
   * Says when the alt text of a tile is past its limit, and marks the tile for `social#canPost`.
   *
   * ⚠️ It counts graphemes, as the count of the words does, and the field has no `maxlength`. The
   * action counts the same way.
   * @param {HTMLElement} tile
   */
  countAltOf(tile) {
    const field = tile.querySelector("[data-photo-alt]");
    const line = tile.querySelector("[data-photo-alt-over]");
    if (!field || !line) return;

    const length = this.graphemes(field.value ?? "");
    const over = length > this.altLimitValue;

    tile.classList.toggle("social-photo--alt-over", over);
    line.hidden = !over;
    line.textContent = over ? t(this.words, "alt_too_long", { count: length, limit: this.altLimitValue }) : "";
  }

  /**
   * The Bluesky field of each mention of the draft, by key.
   *
   * ⚠️ It is a plain data attribute and NOT a Stimulus value. A value arrives through a
   * MutationObserver, thus it is not synchronous, and `social#canPost` reads the count line that
   * this controller writes. The submit button would then follow the keystroke before the current
   * one. `social#pushMentions` writes this attribute and calls `count()` at once.
   * @returns {Object<string, string>}
   */
  get blueskyMentions() {
    try {
      return JSON.parse(this.element.dataset.socialPostBlueskyMentions || "{}");
    } catch {
      return {};
    }
  }

  /**
   * Writes the length of the body against the limit, and colors that line.
   *
   * ⚠️ It counts the text that **Bluesky** will get, and not the words that the owner can see. Two
   * things make those different. A mention grows into a handle, thus "@tony" can become
   * "@tony.bsky.social". And a Markdown link keeps its address in a facet, thus
   * "[my post](https://example.com/a)" is 7 characters and not 30.
   * `Admin::SocialController#post_error` and `Bluesky.post_length` measure the same string.
   *
   * And the typography shortens the words: `...` becomes one character and `--` becomes one.
   *
   * ⚠️ The three steps are in THIS ORDER, as they are on the server: the mentions, then the
   * typography, then the Markdown. A handle can hold no bracket and no dash pair, thus no step can
   * make work for the step below it.
   *
   * ⚠️ `applyLengthRules` writes NO quotation mark, and that is correct: a curly quotation mark is
   * one character in place of one, thus it cannot change a count. Refer to that file.
   *
   * ⚠️ **The LINK is part of this count when the page it names gives no card.** Bluesky then makes
   * no embed and the link goes in the words, thus it uses characters.
   * `Admin::SocialController#bluesky_text` composes the same string on the server. The link goes in
   * between the typography and the Markdown, exactly as it does there.
   */
  count() {
    const body = applyLengthRules(blueskyText(this.bodyTarget.value ?? "", this.blueskyMentions));
    const text = render(this.withLink(body));
    const length = this.graphemes(text);

    this.countTextTarget.textContent = `${length} / ${this.limitValue}`;
    this.announceCount(length);
    // ⚠️ The ring stops at 100: a draft past the limit must not draw more than a full circle. The
    // words beside it are what say how far past it is.
    this.ringTarget.value = Math.min(100, Math.round((length / this.limitValue) * 100));

    this.countTarget.classList.toggle("social__count--warning",
      length >= this.warnAtValue && length <= this.limitValue);
    this.countTarget.classList.toggle("social__count--over", length > this.limitValue);
  }

  /**
   * Tells a screen reader about the count when it crosses the warning or the limit, and not at
   * each keystroke. ⚠️ The count line is not a live region itself: a region that changes at each
   * character reads every number aloud.
   * @param {number} length
   */
  announceCount(length) {
    if (!this.hasCountNoticeTarget) return;

    const state = length > this.limitValue ? "over" : length >= this.warnAtValue ? "warning" : "ok";
    if (state === this.announcedState) return;

    this.announcedState = state;
    this.countNoticeTarget.textContent = state === "ok" ? "" : `${length} / ${this.limitValue}`;
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
   * Adds the link below the words when that link goes in the post.
   *
   * ⚠️ It is false until the preview answers, thus the first count of a page that renders again
   * with a draft in it can be short by the length of a link. `connect()` reads the card at once and
   * writes the count again, and `SocialPresenter#bluesky_length` makes no request at all.
   * @param {string} text
   * @returns {string}
   */
  withLink(text) {
    const url = this.linkInText ? (this.linkTarget.value?.trim() ?? "") : "";

    return [ text.trim(), url ].filter(Boolean).join("\n\n");
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
    if (!this.linkTarget.value?.trim()) return this.clearPreview();

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
    if (!url) return this.clearPreview();

    // ⚠️ Each call takes the next number, and only the newest one may write. A request that is
    // still out when the owner types again must not describe a link that they already replaced,
    // and must not stop the spinner of the request that replaced it.
    this.previewSeq = (this.previewSeq ?? 0) + 1;
    const seq = this.previewSeq;

    this.previewAborter?.abort();
    this.previewAborter = new AbortController();
    try {
      const response = await fetch(`${this.previewUrlValue}?${new URLSearchParams({ url })}`, {
        headers: { Accept: "application/json" },
        signal: this.previewAborter.signal,
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
   * @param {object} card The answer of the preview action.
   */
  showPreview(card) {
    this.previewHostTarget.textContent = card.host ?? "";
    // ⚠️ **The ADDRESS takes the place of a title for a page with no og: tags.** The field is
    // hidden by now, thus this card is the only thing that says which link the post carries, and a
    // host name alone reads the same for two links to one site.
    this.previewTitleTarget.textContent = card.title ?? card.url ?? "";
    this.previewDescriptionTarget.textContent = card.description ?? "";

    // ⚠️ `withMedia` follows the picture. <wa-card> has no `:has-slotted` to read, thus that flag
    // is the only thing that tells it to draw the media section. A card with the flag and no
    // picture draws an empty band above the text.
    this.previewImageTarget.hidden = !card.image_path;
    this.previewTarget.withMedia = !!card.image_path;
    if (card.image_path) this.previewImageTarget.src = card.image_path;

    // ⚠️ The badge shows for the standard.site card ALONE, which the owner cannot know until after
    // the post without it. No badge means the ordinary card from the og: tags.
    this.previewKindTarget.hidden = !card.standard_site;
    if (card.standard_site) this.previewKindTarget.textContent = t(this.words, "shared.standard_site");

    this.setLinkState(ATTACHED);
    // ⚠️ **This card is not the card of Bluesky.** A page with no og: tags gets no embed there, and
    // its link goes in the WORDS instead, thus the count holds it. Refer to
    // `Admin::SocialController#bluesky_text`.
    this.setLinkInText(!card.embeddable);
  }

  /**
   * Stops the wait and the request, and takes the card away. It is the empty field.
   *
   * ⚠️ **It takes the next sequence number**, thus a request that is still out cannot draw the card
   * of a link that the field no longer holds.
   */
  clearPreview() {
    this.previewSeq = (this.previewSeq ?? 0) + 1;
    this.busy(false);
    this.hidePreview();
  }

  /**
   * Takes the card away, for an empty field and for a request that failed.
   *
   * ⚠️ It puts the FIELD back for a card that went away, thus the owner can correct a link that
   * this app could not read. A field that is still being typed stays as it is, and the X of the
   * card is the only way back to the button.
   *
   * ⚠️ It also takes the link out of the count. The action answers with a card for each http URL,
   * even for a page that it could not read, thus this path means "there is no link here" or "we do
   * not know yet", and neither one may count characters that the post may not hold.
   */
  hidePreview() {
    this.dropCardImage();
    if (this.linkState === ATTACHED) this.setLinkState(EDITING);
    this.setLinkInText(false);
  }

  /**
   * Drops the picture of the card, so a stale one never shows with a new link.
   */
  dropCardImage() {
    this.previewTarget.withMedia = false;
    this.previewImageTarget.hidden = true;
    this.previewImageTarget.removeAttribute("src");
  }

  /**
   * ⚠️ It writes the count again, because that count holds the link only in this state.
   * @param {boolean} on
   */
  setLinkInText(on) {
    if (this.linkInText === on) return;

    this.linkInText = on;
    this.count();
  }

  /**
   * Shows or hides the spinner in the link field.
   * @param {boolean} on
   */
  busy(on) {
    this.spinnerTarget.hidden = !on;
  }
}
