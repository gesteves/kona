import { Controller } from "@hotwired/stimulus";
import { i18nTable, t } from "../lib/i18n";
import { render } from "../lib/markdown_links";
import { blueskyText } from "../lib/social_mentions";
import { applyLengthRules } from "../lib/typography";

// How long the link field must be quiet before this reads the card. Each preview is one request of
// this app, which then reads the page of another host.
const PREVIEW_DEBOUNCE = 600;

// The three states of the link of a post, and each one shows one control: the button of the
// toolbar, the field, or the card. ⚠️ The X on the card is the one way back to IDLE.
const IDLE = "idle";
const EDITING = "editing";
const ATTACHED = "attached";

/**
 * One post of the thread: its character count and the preview of its link.
 *
 * ⚠️ Each block is its own controller, and the outer `social` controller never reaches into it.
 * One controller for each block is what keeps the count and the preview of one post away from the
 * others; a flat list of targets on the outer controller would need an index at every call.
 */
export default class extends Controller {
  static targets = [
    "body", "count", "countText", "ring", "link", "spinner", "preview", "previewImage",
    "previewHost", "previewTitle", "previewDescription", "previewKind", "linkButton",
  ];
  static values = { limit: Number, warnAt: Number, previewUrl: String };

  connect() {
    // ⚠️ The words come from the locale file, through the `data-admin-i18n` attribute.
    this.words = i18nTable(this.element);
    this.linkState = IDLE;
    // ⚠️ It waits for the definitions: `value` is undefined on these components until the browser
    // upgrades them. A Turbo restoration visit, and a page that renders again after a refusal, both
    // hold values with no controller state.
    Promise.all(
      ["wa-textarea", "wa-input"].map((tag) => customElements.whenDefined(tag))
    ).then(() => {
      // ⚠️ The state comes from the FIELD, thus it is the state that the server already rendered
      // and nothing moves. `preview()` below promotes it to ATTACHED when the page reads.
      this.linkState = this.linkTarget.value?.trim() ? EDITING : IDLE;
      this.count();
      this.preview();
    });
  }

  /**
   * Opens the link field: the button of the toolbar asks for a link, and Edit on the card takes the
   * owner back to the one that the post carries.
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
   * Shows the one control of this state, and disables the button of the toolbar outside IDLE.
   *
   * ⚠️ The field and the card take turns, and each one carries an X that goes back to IDLE.
   *
   * ⚠️ **The button is DISABLED and never hidden.** It is a form control and it is taller than the
   * count beside it, thus a button that goes away takes the height of the toolbar with it and the
   * count moves up at the click that opened the field.
   */
  renderLinkState() {
    this.linkButtonTarget.disabled = this.linkState !== IDLE;
    this.linkTarget.hidden = this.linkState !== EDITING;
    this.previewTarget.hidden = this.linkState !== ATTACHED;
  }

  /**
   * @param {string} state
   */
  setLinkState(state) {
    this.linkState = state;
    this.renderLinkState();
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
    // ⚠️ The ring stops at 100: a draft past the limit must not draw more than a full circle. The
    // words beside it are what say how far past it is.
    this.ringTarget.value = Math.min(100, Math.round((length / this.limitValue) * 100));

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
    if (card.standard_site) this.previewKindTarget.textContent = t(this.words, "standard_site");

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
