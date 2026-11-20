import { Controller } from "@hotwired/stimulus";
import { i18nTable, t } from "../lib/i18n";
import { toast } from "../lib/toast";
import { PictureTiles } from "../lib/picture_tiles";

// One picked file on the page.
const FILE = "[data-media-upload-target='file']";

/**
 * The media uploader: it picks images, uploads each one at once, asks Claude for the alt text of
 * each one, and collects the words that go with it. `PictureTiles` does the upload and the alt
 * text of each tile.
 *
 * ⚠️ The tiles have NO order. Thus there is no drag code here, and the Social media composer has
 * it.
 */
export default class extends Controller {
  static targets = ["fileInput", "tiles", "fileTemplate", "file", "submit"];
  static values = { url: String, maxFiles: Number };

  connect() {
    this.words = i18nTable(this.element);
    this.pictures = new PictureTiles({
      element: this.element,
      name: "file",
      selector: FILE,
      uploadingClass: "media-file--uploading",
      field: "file",
      words: this.words,
      url: () => this.urlValue,
      template: () => this.fileTemplateTarget,
      container: () => this.tilesTarget,
      tiles: () => this.fileTargets,
      changed: () => this.settle(),
      inserted: (tile, file) => this.nameTile(tile, file),
    });

    // ⚠️ A Web Awesome control has no `value` and no `disabled` before the browser upgrades it.
    Promise.all(
      ["wa-input", "wa-textarea", "wa-button", "wa-file-input"].map((tag) =>
        customElements.whenDefined(tag)
      )
    ).then(() => {
      this.pictures.dropUnfinished();
      this.settle();
    });
  }

  disconnect() {
    this.pictures.stop();
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
    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = this.fileCount === 0 || this.pictures.uploading;
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
    files.slice(0, room).forEach((file) => this.pictures.upload(file));
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
   * Takes one file off the page. It asks nothing: a file is quick to add again.
   * @param {Event} event
   */
  removeFile(event) {
    event.preventDefault();
    const tile = event.target.closest(FILE);
    if (!tile) return;

    this.pictures.drop(tile);
    this.settle();
    this.fileInputTarget.focus();
  }

  /**
   * Asks Claude again for the alt text of a tile, at a click of its Generate control.
   * @param {Event} event
   */
  generateAlt(event) {
    event.preventDefault();
    const tile = event.currentTarget.closest(FILE);
    if (tile) this.pictures.requestAlt(tile);
  }
}
