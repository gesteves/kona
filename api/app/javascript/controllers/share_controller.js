import { Controller } from "@hotwired/stimulus";

/**
 * The Share composer: the article picker, the selection card, and the character count.
 *
 * Nothing here submits. The page drafts a post and no code posts one yet.
 */
export default class extends Controller {
  static targets = ["combobox", "selection", "selectionTitle", "selectionUrl", "body", "count"];
  static values = { limit: Number, warnAt: Number };

  connect() {
    // ⚠️ Each step here waits for the definitions. `filter` is a property of the component and it
    // does not exist before the upgrade, and `value` is undefined until then on both elements.
    //
    // A Turbo restoration visit renders a snapshot that holds the values and no controller state.
    // Thus the card and the count run at connect, and not at the first event only. Before the
    // upgrade they would read nothing, and the card would stay hidden below a value that is there.
    Promise.all([
      customElements.whenDefined("wa-combobox"),
      customElements.whenDefined("wa-textarea")
    ]).then(() => {
      this.comboboxTarget.filter = (option, query) => this.matches(option, query);
      this.pick();
      this.count();
    });
  }

  /**
   * Tells if one option answers what the user typed.
   *
   * It reads the summary and the URL as well as the title. Thus a URL that you paste finds its
   * entry, and a word that is in the summary only still finds one.
   * @param {HTMLElement} option
   * @param {string} query
   * @returns {boolean}
   */
  matches(option, query) {
    const needle = query.trim().toLowerCase();
    if (!needle) return true;

    return ["title", "summary", "url"].some((key) =>
      (option.dataset[key] ?? "").toLowerCase().includes(needle)
    );
  }

  /**
   * Names the selected entry below the picker, and hides the line when nothing is selected.
   */
  pick() {
    const option = this.selected;

    this.selectionTarget.hidden = !option;
    if (!option) return;

    this.selectionTitleTarget.textContent = option.dataset.title ?? "";
    this.selectionUrlTarget.textContent = option.dataset.url ?? "";
  }

  /**
   * Writes the length of the body against the limit, and colors that line.
   */
  count() {
    const length = this.graphemes(this.bodyTarget.value ?? "");

    this.countTarget.textContent = `${length} / ${this.limitValue}`;
    this.countTarget.classList.toggle("share__count--warning",
      length >= this.warnAtValue && length <= this.limitValue);
    this.countTarget.classList.toggle("share__count--over", length > this.limitValue);
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
   * @returns {HTMLElement|null} The option that the picker holds, or null when it holds none.
   */
  get selected() {
    const value = this.comboboxTarget.value;
    if (!value) return null;

    return this.comboboxTarget.querySelector(`wa-option[value="${CSS.escape(value)}"]`);
  }
}
