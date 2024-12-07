import { Controller } from "@hotwired/stimulus";
import ClipboardJS from 'clipboard';

export default class extends Controller {
  static classes = ['hidden']
  static targets = ['button', 'link', 'check'];

  connect() {
    this.clipboard = new ClipboardJS(this.buttonTarget, {
      text: () => this.buttonTarget.getAttribute('href')
    });

    this.clipboard.on('success', () => this.successfulCopy());
    this.clipboard.on('error', () => this.unsuccessfulCopy());
  }

  disconnect() {
    this.clipboard.destroy();
  }

  /**
   * Convenience method to stop the button from doing its thing.
   * @param  {Event} event Click event from the button.
   */
  preventDefault (event) {
    event.preventDefault();
  }

  /**
   * Handle successful copy event.
   */
  successfulCopy() {
    // Hide the link icon and show the circle-check icon
    this.linkTarget.classList.add(this.hiddenClass);
    this.checkTarget.classList.remove(this.hiddenClass);

    // Revert back after 5 seconds
    setTimeout(() => {
      this.linkTarget.classList.remove(this.hiddenClass);
      this.checkTarget.classList.add(this.hiddenClass);
    }, 2000);
  }

  /**
   * Handle unsuccessful copy event.
   */
  unsuccessfulCopy() {
    console.error('Failed to copy link. Please try again.');
  }
}
