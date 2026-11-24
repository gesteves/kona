import { isBlueskyHandle, mentionKey, tokensOf } from "./social_mentions";

// How long the words must be quiet before the rows are reconciled. ⚠️ A token churns while the
// owner types it — "@t", "@to", "@ton" — and a row for each of those would take the focus.
const MENTION_DEBOUNCE = 250;

/**
 * The mention rows of the Social media page: one row for each @token of the draft, with one field
 * for each network. The `social` controller makes one, and gives it each element that it needs.
 *
 * ⚠️ The map is thread-level, thus a token in post 1 and in post 3 is one row.
 */
export class MentionRows {
  /**
   * @param {object} options
   * @param {HTMLElement} options.section The section, which is hidden while the draft names nobody.
   * @param {HTMLElement} options.container The element that holds the rows.
   * @param {HTMLTemplateElement} options.template One empty row.
   * @param {function(): HTMLElement[]} options.rows Gives the rows that are in the page now.
   * @param {function(): string[]} options.texts Gives the words of each post of the draft.
   * @param {function(): void} options.changed Runs after a scan changed the rows.
   */
  constructor({ section, container, template, rows, texts, changed }) {
    this.section = section;
    this.container = container;
    this.template = template;
    this.rows = rows;
    this.texts = texts;
    this.changed = changed;

    // The values of each mention, by key. ⚠️ A value stays here after its row goes away, thus a
    // token that the owner deletes and writes again gets its handles back.
    this.values = new Map();
  }

  /** Stops the scan that waits. */
  stop() {
    clearTimeout(this.timer);
  }

  /**
   * Reads each row of the mention section into the Map.
   *
   * ⚠️ It runs BEFORE the scan, thus a row that the scan is about to remove has its values kept.
   */
  read() {
    this.rows().forEach((row) => {
      const token = row.querySelector("[data-mention-token]")?.value ?? "";
      if (!token) return;

      const handles = {};
      row.querySelectorAll("[data-mention-network]").forEach((field) => {
        handles[field.dataset.mentionNetwork] = field.value ?? "";
      });

      this.values.set(mentionKey(token), { token, handles });
    });
  }

  /** @returns {string} The Bluesky field of each mention, by key, as JSON. */
  get blueskyJson() {
    const map = {};
    this.values.forEach((entry, key) => {
      const value = entry.handles?.bluesky?.trim();
      if (value) map[key] = value;
    });

    return JSON.stringify(map);
  }

  /**
   * Waits for the typing to stop, then reconciles the rows.
   */
  scheduleScan() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.scan(), MENTION_DEBOUNCE);
  }

  /**
   * Makes the rows of the section match the tokens of the draft.
   *
   * ⚠️ It RECONCILES and it never renders the section again. A rebuild would take the focus and
   * lose each value at every keystroke.
   */
  scan() {
    this.read();

    // The tokens of the whole draft. ⚠️ The map is thread-level, thus a token in post 1 and in
    // post 3 is one row. The first spelling wins, and that is the one that a network with no
    // handle will show.
    const wanted = new Map();
    this.texts().forEach((words) => {
      tokensOf(words).forEach((token) => {
        const key = mentionKey(token);
        if (!wanted.has(key)) wanted.set(key, token);
      });
    });

    // ⚠️ A row that goes away keeps its values in the Map above, thus a token that comes back gets
    // them again.
    this.rows().forEach((row) => {
      if (!wanted.has(this.keyOfRow(row))) row.remove();
    });

    wanted.forEach((token, key) => {
      if (this.rowFor(key)) return;

      this.container.appendChild(this.buildRow(token, key));
    });

    // ⚠️ A node that moves loses the focus, thus the rows are not put in order while the owner is
    // typing in one of them. The next scan does it.
    if (!this.container.contains(document.activeElement)) {
      wanted.forEach((_token, key) => {
        const row = this.rowFor(key);
        if (row) this.container.appendChild(row);
      });
    }

    // ⚠️ A new row seeds its own field, and the read at the top of this method ran before that
    // row existed. Without this second read, the first count after a new mention is not the
    // number that the server counts.
    this.read();

    this.section.hidden = wanted.size === 0 || !this.hasFields;
    this.changed();
  }

  /**
   * Makes one row from the template, with the values that the owner already gave.
   * @returns {HTMLElement}
   */
  buildRow(token, key) {
    const row = this.template.content.cloneNode(true)
      .querySelector("[data-social-target='mention']");
    const stored = this.values.get(key);

    row.querySelector("[data-mention-token]").value = token;
    const label = row.querySelector("[data-mention-label]");
    if (label) {
      label.textContent = token;
      // The same id that the server renders: the row is a group that the token names.
      label.id = `mention-${key}`;
      row.setAttribute("aria-labelledby", label.id);
    }

    row.querySelectorAll("[data-mention-network]").forEach((field) => {
      const network = field.dataset.mentionNetwork;
      field.value = stored?.handles?.[network] || this.seedFor(token, network);
    });

    return row;
  }

  /**
   * The value to put in a field of a new row.
   *
   * ⚠️ A token that is already a handle seeds its own field. Nothing seeds Threads: a bare
   * "@name" is the ambiguous case, and a guess there is what tags a stranger.
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
  get hasFields() {
    return !!this.template.content.querySelector("[data-mention-network]");
  }

  /** @param {HTMLElement} row @returns {string} */
  keyOfRow(row) {
    return mentionKey(row.querySelector("[data-mention-token]")?.value ?? "");
  }

  /** @param {string} key @returns {HTMLElement|undefined} */
  rowFor(key) {
    return this.rows().find((row) => this.keyOfRow(row) === key);
  }
}
