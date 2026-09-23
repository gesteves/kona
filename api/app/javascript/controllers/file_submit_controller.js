import { Controller } from "@hotwired/stimulus";

/**
 * Keeps the submit button of an upload form off while the file input holds no file.
 *
 * The server renders the button `disabled`. `connect` checks the input again, because a Turbo
 * restoration visit can show the form with files still in it.
 */
export default class extends Controller {
  static targets = ["input", "submit"];

  connect() {
    this.update();
  }

  /** Sets the button on when the input holds one file or more. */
  update() {
    this.submitTarget.disabled = (this.inputTarget.files?.length ?? 0) === 0;
  }
}
