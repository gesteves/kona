import { Controller } from "@hotwired/stimulus";
import { i18nTable, t } from "../lib/i18n";
import { render } from "../lib/markdown_links";
import { blueskyText } from "../lib/social_mentions";
import { applyLengthRules } from "../lib/typography";

// How long the link field must be quiet before this reads the card. Each preview is one request of
// this app, which then reads the page of another host.
const PREVIEW_DEBOUNCE = 600;

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
    "previewHost", "previewTitle", "previewDescription", "previewKind", "previewNote",
  ];
  static values = { limit: Number, warnAt: Number, previewUrl: String };

  connect() {
    // ⚠️ The words come from the locale file, through the `data-admin-i18n` attribute.
    this.words = i18nTable(this.element);
    // ⚠️ It waits for the definitions: `value` is undefined on these components until the browser
    // upgrades them. A Turbo restoration visit, and a page that renders again after a refusal, both
    // hold values with no controller state.
    Promise.all(
      ["wa-textarea", "wa-input"].map((tag) => customElements.whenDefined(tag))
    ).then(() => {
      this.count();
      this.preview();
    });
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
   * @param {object} card The answer of the preview action.
   */
  showPreview(card) {
    // ⚠️ A page with no og: tags draws no card at all: Bluesky makes no embed from it, and the link
    // goes in the words instead. The note below says so, and the count then holds that link.
    if (!card.embeddable) return this.showNoCard();

    this.previewNoteTarget.hidden = true;
    this.previewHostTarget.textContent = card.host ?? "";
    this.previewTitleTarget.textContent = card.title ?? "";
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

    this.previewTarget.hidden = false;
    this.setLinkInText(false);
  }

  /**
   * Hides the card and says that the link goes in the words of the post.
   */
  showNoCard() {
    this.hideCard();
    this.previewNoteTarget.hidden = false;
    this.setLinkInText(true);
  }

  /**
   * Hides the card and the note, for an empty field and for a request that failed.
   *
   * ⚠️ It also takes the link out of the count. The action answers with a card for each http URL,
   * even for a page that it could not read, thus this path means "there is no link here" or "we do
   * not know yet", and neither one may count characters that the post may not hold.
   */
  hidePreview() {
    this.hideCard();
    this.previewNoteTarget.hidden = true;
    this.setLinkInText(false);
  }

  /**
   * Hides the card, and drops the picture so a stale one never shows with a new link.
   */
  hideCard() {
    this.previewTarget.hidden = true;
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
