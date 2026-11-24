import { t } from "./i18n";
import { toast } from "./toast";
import { csrfHeader } from "./csrf";

/**
 * The tiles of the pictures that a page uploads, one request for each picture. The Social media
 * composer and the media uploader both use it.
 *
 * ⚠️ Each picture uploads at the moment the owner picks it, and the form then carries the id and
 * not the bytes. The server cannot fill a file input again, thus a page that renders again after
 * a refusal would lose each picture.
 *
 * The hooks of a tile are `data-<name>-*` attributes, and the caller gives the name: `photo` for
 * the composer and `file` for the uploader. A tile has `-id`, `-image`, `-spinner`, and `-alt`,
 * an optional `-generate` control, and its own `data-<name>-alt-url`.
 *
 * The words come from the table of the caller: `upload_failed`, `upload_unreachable`,
 * `alt_failed`, and `alt_unreachable`.
 */
export class PictureTiles {
  /**
   * @param {object} options
   * @param {HTMLElement} options.element The element of the controller that owns the tiles.
   * @param {string} options.name The name in the hooks of a tile.
   * @param {string} options.selector The selector of one tile.
   * @param {string} options.uploadingClass The class of a tile whose upload is still out.
   * @param {string} options.field The name of the form field that carries the file.
   * @param {object} options.words The i18n table of the caller.
   * @param {function(): string} options.url Gives the URL that takes an upload.
   * @param {function(): HTMLTemplateElement} options.template Gives the template of an empty tile.
   * @param {function(): HTMLElement} options.container Gives the element that holds the tiles.
   * @param {function(): HTMLElement[]} options.tiles Gives the tiles on the page.
   * @param {function(): void} options.changed Runs after an upload adds, fills, or removes a tile.
   * @param {function(HTMLElement, File): void} [options.inserted] Runs after a new tile enters the
   *   document. ⚠️ A `<wa-*>` control upgrades at that moment, and a value that code writes before
   *   it goes on a plain object property.
   */
  constructor(options) {
    Object.assign(this, options);
    // The upload of each tile that is still out, by tile. `stop()` and `drop()` abort it.
    this.uploads = new Map();
    // The alt text request of each tile that is still out, by tile, with the same rule.
    this.generations = new Map();
  }

  /** @returns {boolean} True while an upload is still out. */
  get uploading() {
    return this.uploads.size > 0;
  }

  /** @returns {string} The selector of one hook of a tile, for example of "image". */
  hook(part) {
    return `[data-${this.name}-${part}]`;
  }

  /**
   * Stops each request that is out, and frees each object URL.
   *
   * ⚠️ A Turbo visit disconnects the controller, and a late answer would write into a page that
   * is gone. The browser keeps the bytes of an object URL until the page revokes it.
   */
  stop() {
    this.uploads.forEach((aborter) => aborter.abort());
    this.uploads.clear();
    this.generations.forEach((aborter) => aborter.abort());
    this.generations.clear();
    this.tiles().forEach((tile) => this.revokePreview(tile));
  }

  /**
   * Adds a tile for one file and uploads it.
   *
   * ⚠️ The tile is on the page at once, with the file itself as its picture: the CSP of the admin
   * permits `blob:` in `img-src` for this. Its id stays empty until the server answers, and the
   * caller keeps its submit off while a tile is in that state.
   *
   * ⚠️ A refusal removes the tile, and a toast shows the reason that the server names.
   */
  async upload(file) {
    const tile = this.build(file);
    this.container().appendChild(tile);
    this.inserted?.(tile, file);

    const aborter = new AbortController();
    this.uploads.set(tile, aborter);
    this.changed();

    const body = new FormData();
    body.append(this.field, file, file.name);

    try {
      const response = await fetch(this.url(), {
        method: "POST",
        headers: { Accept: "application/json", ...csrfHeader() },
        body,
        signal: aborter.signal,
      });
      const answer = await response.json().catch(() => ({}));

      if (!response.ok) {
        this.drop(tile);
        toast(answer.error || t(this.words, "upload_failed"), "danger");
        return;
      }
      this.fill(tile, answer);
      // ⚠️ No `await`. The submit waits for each upload, and it must not wait for Claude too.
      this.requestAlt(tile, { auto: true });
    } catch {
      // A remove or a Turbo visit aborted it, and the tile is already gone.
      if (aborter.signal.aborted) return;

      this.drop(tile);
      toast(t(this.words, "upload_unreachable"), "danger");
    } finally {
      this.uploads.delete(tile);
      if (this.element.isConnected) this.changed();
    }
  }

  /**
   * Makes the tile of a file that is still out, from the template. It shows the picture from the
   * browser, thus the tile is complete before the server answers.
   */
  build(file) {
    const tile = this.template().content.cloneNode(true).querySelector(this.selector);
    tile.classList.add(this.uploadingClass);
    tile.querySelector(this.hook("spinner")).hidden = false;

    const image = tile.querySelector(this.hook("image"));
    image.src = URL.createObjectURL(file);
    image.dataset.objectUrl = image.src;

    return tile;
  }

  /**
   * Writes the answer of the server into the tile.
   *
   * ⚠️ The picture changes to the path of our own store only after that copy loads, thus the tile
   * never shows an empty box. The code revokes the object URL at that moment.
   * @param {object} answer `{ id, path, alt_path, caption }`
   */
  fill(tile, answer) {
    tile.querySelector(this.hook("id")).value = answer.id ?? "";
    tile.classList.remove(this.uploadingClass);
    tile.querySelector(this.hook("spinner")).hidden = true;

    // The Generate control can run once the picture has an id and a path of its own.
    tile.dataset[`${this.name}AltUrl`] = answer.alt_path ?? "";
    const generate = tile.querySelector(this.hook("generate"));
    if (generate) generate.disabled = !answer.alt_path;

    // ⚠️ The caption of the file goes into an EMPTY field only, before the automatic request.
    // That request then sees a value and asks Claude for nothing.
    const alt = tile.querySelector(this.hook("alt"));
    if (answer.caption && alt && !alt.value?.trim()) {
      alt.value = answer.caption;
      alt.dispatchEvent(new Event("input", { bubbles: true }));
    }

    const image = tile.querySelector(this.hook("image"));
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
   * Removes a tile, and stops its upload and its alt text request when one is out.
   *
   * ⚠️ It sends no DELETE. The stored record has a TTL, and a request from the browser is not
   * reliable, because a navigation cancels it.
   */
  drop(tile) {
    this.uploads.get(tile)?.abort();
    this.uploads.delete(tile);
    this.generations.get(tile)?.abort();
    this.generations.delete(tile);
    this.revokePreview(tile);
    tile.remove();
  }

  /**
   * Removes each tile whose upload never finished.
   *
   * ⚠️ A Turbo snapshot can hold such a tile: it has no id, and nothing can finish it. The action
   * would drop it, thus the page removes it and says nothing.
   * @returns {number} The number of tiles that went.
   */
  dropUnfinished() {
    const unfinished = this.tiles().filter((tile) => !tile.querySelector(this.hook("id"))?.value);
    unfinished.forEach((tile) => this.drop(tile));
    return unfinished.length;
  }

  /** Gives the browser back the bytes of the picture of a tile. */
  revokePreview(tile) {
    const image = tile.querySelector(this.hook("image"));
    if (!image?.dataset.objectUrl) return;

    URL.revokeObjectURL(image.dataset.objectUrl);
    delete image.dataset.objectUrl;
  }

  /**
   * Asks Claude for the alt text of the picture of a tile, and writes the answer into its field.
   *
   * ⚠️ The button is `loading` and `disabled` while the request is out. `loading` draws the busy
   * state, and the docs do not say that it stops a click, thus `disabled` does. The
   * `button.loading` check stops a second request before the render.
   *
   * ⚠️ A click replaces the field, because the owner asked for new words. The automatic request
   * writes into an empty field only: the words of the owner and the caption of the file win. A
   * value that code writes fires no event, thus this dispatches `input` on the field. A refusal
   * leaves the field as it was and says why in a toast.
   *
   * ⚠️ It runs only when the tile has the Generate control. The server renders that control only
   * with a Claude key, thus with no key the upload asks for nothing.
   * @param {boolean} [options.auto] True for the request that the upload starts.
   */
  async requestAlt(tile, { auto = false } = {}) {
    const button = tile.querySelector(this.hook("generate"));
    const field = tile.querySelector(this.hook("alt"));
    const url = tile.dataset[`${this.name}AltUrl`];
    if (!button || !field || !url || button.loading) return;
    if (auto && field.value?.trim()) return;

    button.loading = true;
    button.disabled = true;
    const aborter = new AbortController();
    this.generations.set(tile, aborter);

    try {
      const response = await fetch(url, {
        method: "POST",
        headers: { Accept: "application/json", ...csrfHeader() },
        signal: aborter.signal,
      });
      const answer = await response.json().catch(() => ({}));

      if (!response.ok) {
        toast(answer.error || t(this.words, "alt_failed"), "danger");
        return;
      }
      if (auto && field.value?.trim()) return;

      field.value = answer.alt ?? "";
      field.dispatchEvent(new Event("input", { bubbles: true }));
    } catch {
      // A remove or a Turbo visit aborted it, and there is nothing to say.
      if (aborter.signal.aborted) return;

      toast(t(this.words, "alt_unreachable"), "danger");
    } finally {
      this.generations.delete(tile);
      if (tile.isConnected) {
        button.loading = false;
        button.disabled = false;
      }
    }
  }
}
