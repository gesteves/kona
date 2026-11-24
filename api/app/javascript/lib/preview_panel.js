import { csrfHeader } from "./csrf";
import { t } from "./i18n";

// How long a change must be quiet before the open preview is read again. ⚠️ Only the mentions and
// the topic can change while that panel is on screen, thus this is rare and it can be short.
const PREVIEW_DEBOUNCE = 300;

/**
 * The Preview panel of the Social media page: the draft as each network will receive it. The
 * `social` controller makes one, and gives it each element that it needs.
 */
export class PreviewPanel {
  /**
   * @param {object} options
   * @param {HTMLFormElement} options.form The form of the draft, which goes to the action.
   * @param {function(): string} options.url Gives the URL of the preview action.
   * @param {HTMLElement} options.body The element that holds one group for each network.
   * @param {HTMLElement} options.empty The line for a draft that ticks no network.
   * @param {HTMLElement} options.spinner
   * @param {HTMLTemplateElement} options.groupTemplate One network, and its posts below it.
   * @param {HTMLTemplateElement} options.rowTemplate One post of a thread.
   * @param {function(): HTMLElement[]} options.networks Gives the checkbox of each network.
   * @param {object} options.words The i18n table of the controller.
   */
  constructor({ form, url, body, empty, spinner, groupTemplate, rowTemplate, networks, words }) {
    this.form = form;
    this.url = url;
    this.body = body;
    this.empty = empty;
    this.spinner = spinner;
    this.groupTemplate = groupTemplate;
    this.rowTemplate = rowTemplate;
    this.networks = networks;
    this.words = words;
  }

  /** Stops the refresh that waits and the request that is out. */
  stop() {
    clearTimeout(this.timer);
    this.seq = (this.seq ?? 0) + 1;
    this.aborter?.abort();
  }

  /**
   * Reads the draft again after the owner changes something while the preview is open.
   *
   * ⚠️ The words of a post cannot change here: they are in the Write panel. This is for the
   * mentions and the topic, which the server writes into the text.
   */
  scheduleRefresh() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.load(), PREVIEW_DEBOUNCE);
  }

  /**
   * Hides the row of each network that the owner did not tick.
   *
   * ⚠️ The action answers with every CONNECTED network, and the ticks decide what a post goes to.
   * Thus this filter needs no request of its own.
   */
  filter() {
    const wanted = this.networks().filter((box) => box.checked && !box.disabled)
                       .map((box) => box.value);
    const groups = [ ...this.body.querySelectorAll("[data-preview-network]") ];
    groups.forEach((group) => {
      group.hidden = !wanted.includes(group.dataset.previewNetwork);
    });

    // ⚠️ The line shows only when the panel HOLDS a group and none of them is wanted. An empty
    // draft has its own message, and the two must not both appear.
    const empty = groups.length > 0 && groups.every((group) => group.hidden);
    this.empty.textContent = empty ? t(this.words, "preview_no_network") : "";
    this.empty.hidden = !empty;
  }

  /**
   * Fills the preview panel with the draft as each network will receive it. It reads the draft at
   * the click, thus it needs no debounce.
   *
   * ⚠️ `FormData(this.form)` sends every field that a real submit sends, thus the request needs
   * no list of the fields.
   * ⚠️ It sends the CSRF token in a header of its own, from `lib/csrf.js`. No spec can prove that
   * the token in the body alone would pass, because the test environment has no token.
   */
  async load() {
    this.body.replaceChildren();
    this.empty.hidden = true;
    this.spinner.hidden = false;

    // ⚠️ A second click while one request is out must not let the older answer write. It is the
    // rule that `social-post#preview` follows for the card of a link.
    this.seq = (this.seq ?? 0) + 1;
    const seq = this.seq;

    this.aborter?.abort();
    this.aborter = new AbortController();
    try {
      const response = await fetch(this.url(), {
        method: "POST",
        headers: { Accept: "application/json", ...csrfHeader() },
        body: new FormData(this.form),
        signal: this.aborter.signal,
      });
      if (seq !== this.seq) return;

      if (!response.ok) return this.showMessage("preview_failed");
      this.show(await response.json());
    } catch {
      if (seq === this.seq) this.showMessage("preview_failed");
    } finally {
      if (seq === this.seq) this.spinner.hidden = true;
    }
  }

  /**
   * Writes one group for each post, and one row for each network below it.
   * @param {object} draft The answer of the preview action.
   */
  show(draft) {
    // ⚠️ The Preview tab is off for a draft with nothing in it, thus this is a fallback: a panel
    // that stays blank says nothing at all.
    const networks = draft?.networks ?? [];
    if (networks.length === 0) return this.showMessage("preview_empty");

    const body = this.body;
    body.replaceChildren();

    networks.forEach((network) => {
      const group = this.cloneTemplate(this.groupTemplate, ".social-preview__group");

      // ⚠️ `filter` reads this to hide the group of a network that the owner unticks.
      group.dataset.previewNetwork = network.key;
      group.querySelector("[data-preview-name]").textContent = network.name;

      const cards = group.querySelector("[data-preview-cards]");
      network.posts.forEach((post) => cards.appendChild(this.card(post)));
      body.appendChild(group);
    });

    // ⚠️ The answer holds each connected network, thus the new groups need the filter at once.
    this.filter();
  }

  /**
   * One card: one post of one network.
   * @param {object} post
   * @returns {HTMLElement}
   */
  card(post) {
    const card = this.cloneTemplate(this.rowTemplate, ".social-preview__card");
    const count = card.querySelector("[data-preview-count]");

    count.textContent = `${post.length} / ${post.limit}`;
    // ⚠️ The modifier goes on the LINE and not on the number, thus one rule colors the words and
    // the ring together.
    card.querySelector(".social-preview__meta")
        .classList.toggle("social-preview__meta--over", post.over);
    // ⚠️ It stops at 100, as the ring of the Write panel does: a post past the limit must not draw
    // more than a full circle.
    card.querySelector("[data-preview-ring]").value =
      Math.min(100, Math.round((post.length / post.limit) * 100));
    card.querySelector("[data-preview-text]").replaceChildren(...this.textNodes(post.segments));

    // The topic, above the words, as a badge. Only one network takes one.
    const topic = card.querySelector("[data-preview-topic]");
    if (post.topic) {
      topic.textContent = post.topic;
      topic.hidden = false;
    }

    // The link of a network that keeps it out of the text and whose card this app cannot draw.
    // ⚠️ It reuses `textNodes`, thus this address opens in the same way as one inside a text.
    const link = card.querySelector("[data-preview-link]");
    if (post.link) {
      link.replaceChildren(...this.textNodes([ { text: post.link, url: post.link } ]));
      link.hidden = false;
    }

    // The website card that Bluesky renders for the link. ⚠️ Only that network carries one: this
    // app builds its embed, and Meta renders its own attachment for Threads.
    this.fillLinkCard(card, post.card);

    // The photos of a post, as thumbnails. ⚠️ The action sends them only on the row of a network
    // that takes photos. Each `src` is the path of our own store.
    const photos = card.querySelector("[data-preview-photos]");
    if (post.photos?.length) {
      photos.replaceChildren(...post.photos.map((photo) => {
        const image = document.createElement("img");
        image.src = photo.path;
        image.alt = photo.alt ?? "";
        return image;
      }));
      photos.hidden = false;
    }

    return card;
  }

  /**
   * Fills the website card of a post, or leaves it away. `SocialPreview#card_json` answers this
   * card and the one that `social-post#showPreview` writes below the link field.
   *
   * ⚠️ The two do NOT draw the same set of cards, on purpose. This one is what the network will
   * render, thus the action sends none for a page with no og: tags. The card of the composer says
   * which link the post carries, thus it draws one for that same page.
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

    // ⚠️ The badge shows for the standard.site card ALONE, which the owner cannot know without it.
    // No badge means the ordinary card from the og: tags.
    const kind = card.querySelector("[data-preview-card-kind]");
    kind.hidden = !link.standard_site;
    if (link.standard_site) kind.textContent = t(this.words, "shared.standard_site");

    element.hidden = false;
  }

  /**
   * The text of one network, in pieces, with each link as a link.
   *
   * ⚠️ A Markdown link shows its words and never its address, thus an `<a>` is the only thing
   * that says where those words point.
   * ⚠️ It writes each piece with `textContent` and `href`, and never with HTML. The action gives
   * a `url` that is http or https only, thus no draft can make a `javascript:` link.
   * @param {Array<{text: string, url?: string}>} segments
   * @returns {Node[]}
   */
  textNodes(segments) {
    return (segments ?? []).map((segment) => {
      if (!segment.url) return document.createTextNode(segment.text);

      const link = document.createElement("a");
      link.href = segment.url;
      link.textContent = segment.text;
      // ⚠️ The page holds the draft. A link that replaced this page would lose it.
      link.target = "_blank";
      link.rel = "noopener noreferrer";

      return link;
    });
  }

  /**
   * Writes one line in the preview panel. ⚠️ A panel that stays empty says nothing at all.
   * @param {string} key A key below `admin.js.social`.
   */
  showMessage(key) {
    const line = document.createElement("p");
    line.textContent = t(this.words, key);
    this.body.replaceChildren(line);
  }

  /**
   * @param {HTMLTemplateElement} template
   * @param {string} selector
   * @returns {HTMLElement}
   */
  cloneTemplate(template, selector) {
    return template.content.cloneNode(true).querySelector(selector);
  }
}
