import { Controller } from "@hotwired/stimulus";
import { i18nTable, t } from "../lib/i18n";
import { toast } from "../lib/toast";
import { csrfHeader } from "../lib/csrf";

// One picked file on the page.
const FILE = "[data-media-upload-target='file']";

/**
 * The media uploader: it picks images, uploads each one at once, and collects the words that go
 * with it.
 *
 * ⚠️ **Each file uploads at the moment the owner picks it**, and the form then carries the id and
 * not the bytes. A file input cannot be refilled by the server, thus a page that renders again
 * after a refusal would lose every file, and the words are the expensive part of this page.
 *
 * ⚠️ The tiles have NO order. Thus there is no drag code here, and the Social media composer has
 * it.
 */
export default class extends Controller {
  static targets = ["fileInput", "tiles", "fileTemplate", "file", "submit"];
  static values = { url: String, maxFiles: Number };

  connect() {
    this.words = i18nTable(this.element);
    // The upload of each tile that is still out, by tile. `disconnect()` and a remove abort it.
    this.uploads = new Map();
    // The alt text request of each tile that is still out, by tile, with the same rule.
    this.generations = new Map();

    // ⚠️ A Web Awesome control has no `value` and no `disabled` before the browser upgrades it.
    Promise.all(
      ["wa-input", "wa-textarea", "wa-button", "wa-file-input"].map((tag) =>
        customElements.whenDefined(tag)
      )
    ).then(() => {
      this.dropUnfinishedFiles();
      this.settle();
    });
  }

  disconnect() {
    this.uploads.forEach((aborter) => aborter.abort());
    this.uploads.clear();
    this.generations.forEach((aborter) => aborter.abort());
    this.generations.clear();
    this.fileTargets.forEach((tile) => this.revokePreview(tile));
  }

  /** @returns {number} The number of tiles on the page. */
  get fileCount() {
    return this.fileTargets.length;
  }

  /**
   * Turns the submit on or off, and turns the picker off at the most files.
   *
   * ⚠️ A tile whose upload is still out has no id, and the action would drop it. Thus the submit
   * waits for every upload.
   */
  settle() {
    const uploading = this.fileTargets.some((tile) => this.uploads.has(tile));

    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = this.fileCount === 0 || uploading;
    }
    this.fileInputTarget.disabled = this.fileCount >= this.maxFilesValue;
  }

  /**
   * Starts an upload for each file that the owner picked.
   *
   * ⚠️ It empties the input. The component would otherwise draw a file list of its own beside the
   * tiles, and a second pick of the same file would fire no `change`.
   */
  filesPicked() {
    const files = [...(this.fileInputTarget.files ?? [])];
    if (files.length === 0) return;
    this.fileInputTarget.files = [];

    const room = Math.max(0, this.maxFilesValue - this.fileCount);
    if (files.length > room) {
      toast(t(this.words, "too_many_files", { limit: this.maxFilesValue }), "warning");
    }
    files.slice(0, room).forEach((file) => this.upload(file));
  }

  /**
   * Sends one file, and fills its tile with the answer.
   *
   * The server refuses a file that is not a picture, one that is too large, and one that
   * Contentful would not take, and the toast shows those words.
   * @param {File} file
   */
  async upload(file) {
    const tile = this.buildTile(file);
    this.tilesTarget.appendChild(tile);
    // ⚠️ AFTER the insert. A <wa-*> control upgrades when it enters the document, and a value that
    // the code writes before that goes on a plain object property.
    this.nameTile(tile, file);

    const aborter = new AbortController();
    this.uploads.set(tile, aborter);
    this.settle();

    const body = new FormData();
    body.append("file", file, file.name);

    try {
      const response = await fetch(this.urlValue, {
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
      if (aborter.signal.aborted) return; // a remove or a Turbo visit
      this.dropTile(tile);
      toast(t(this.words, "upload_unreachable"), "danger");
    } finally {
      this.uploads.delete(tile);
      if (this.element.isConnected) this.settle();
    }
  }

  /**
   * Makes the tile of a file that is still going up. It shows the picture from the browser, thus
   * the tile is complete before the server answers.
   * @param {File} file
   * @returns {HTMLElement}
   */
  buildTile(file) {
    const tile = this.fileTemplateTarget.content.cloneNode(true).querySelector(FILE);
    tile.classList.add("media-file--uploading");
    tile.querySelector("[data-file-spinner]").hidden = false;

    const image = tile.querySelector("[data-file-image]");
    image.src = URL.createObjectURL(file);
    image.dataset.objectUrl = image.src;
    return tile;
  }

  /**
   * Fills the title of a tile with the name of the file and no extension, which is what the
   * server answers as well. The owner can then change it while the upload is still out.
   * @param {HTMLElement} tile
   * @param {File} file
   */
  nameTile(tile, file) {
    const title = tile.querySelector("[data-file-title]");
    if (title) title.value = file.name.replace(/\.[^.]+$/, "");
  }

  /**
   * Writes the answer of the upload into a tile.
   * @param {HTMLElement} tile
   * @param {object} answer `{ id, path, alt_path, title }`.
   */
  fillTile(tile, answer) {
    tile.querySelector("[data-file-id]").value = answer.id ?? "";
    tile.classList.remove("media-file--uploading");
    tile.querySelector("[data-file-spinner]").hidden = true;

    // The Generate control can run once the file has an id and a path of its own.
    tile.dataset.fileAltUrl = answer.alt_path ?? "";
    const generate = tile.querySelector("[data-file-generate]");
    if (generate) generate.disabled = !answer.alt_path;

    const image = tile.querySelector("[data-file-image]");
    const stored = new Image();
    // It preloads the stored copy and swaps after that, thus there is no empty box between the
    // two pictures.
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
   * Takes one file off the page. It asks nothing: a file is quick to add again.
   *
   * ⚠️ It sends no DELETE. The staged record has a TTL, and a request from the browser is not
   * reliable, because a navigation cancels it.
   * @param {Event} event
   */
  removeFile(event) {
    event.preventDefault();
    const tile = event.target.closest(FILE);
    if (!tile) return;

    this.dropTile(tile);
    this.settle();
    this.fileInputTarget.focus();
  }

  /** Stops the work of a tile and removes it. */
  dropTile(tile) {
    this.uploads.get(tile)?.abort();
    this.uploads.delete(tile);
    this.generations.get(tile)?.abort();
    this.generations.delete(tile);
    this.revokePreview(tile);
    tile.remove();
  }

  /**
   * ⚠️ A Turbo snapshot can hold a tile whose upload never finished, and nothing can finish it.
   * The action would drop such a triple, thus the page removes it and says nothing.
   */
  dropUnfinishedFiles() {
    const unfinished = this.fileTargets.filter((tile) => !tile.querySelector("[data-file-id]")?.value);
    unfinished.forEach((tile) => this.dropTile(tile));
  }

  /** Frees the object URL of the picture that came from the browser. */
  revokePreview(tile) {
    const image = tile.querySelector("[data-file-image]");
    if (!image?.dataset.objectUrl) return;

    URL.revokeObjectURL(image.dataset.objectUrl);
    delete image.dataset.objectUrl;
  }

  /**
   * Asks Claude for the alt text of the picture of a tile, and writes the answer into its field.
   *
   * ⚠️ The answer REPLACES the field. The owner asked for it, thus a merge with what is there is
   * not what they want.
   * @param {Event} event
   */
  async generateAlt(event) {
    event.preventDefault();
    const button = event.currentTarget;
    if (button.loading) return;

    const tile = button.closest(FILE);
    const url = tile?.dataset.fileAltUrl;
    if (!url) return;

    // ⚠️ Both: `loading` draws the busy state and keeps the width, and nothing says that it stops
    // a click.
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

      const field = tile.querySelector("[data-file-alt]");
      field.value = answer.alt ?? "";
      field.dispatchEvent(new Event("input", { bubbles: true }));
    } catch {
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
