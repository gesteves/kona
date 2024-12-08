import { Controller } from "@hotwired/stimulus";
import Handlebars from "handlebars";

/**
 * Controls the notifications.
 * @extends Controller
 */
export default class extends Controller {
  static classes = ['transparent', 'closed'];
  static targets = ['container', 'notification', 'template'];

  connect () {
    this.toggle();
  }

  /**
   * Adds a new notification to the notifications container
   * @param {Event} event Custom `notify` event.
   */
  add (event) {
    const status = event.detail.status;
    const message = event.detail.message;
    // Get the Handlebars template from the target element
    const template = this.templateTarget.innerHTML;
    // Compile the Handlebars template
    const compiledTemplate = Handlebars.compile(template);
    // Render the compiled template with data
    const rendered = compiledTemplate({ message: message, status: status });
    

    if (this.hasNotificationTarget) {
      this.closeAll();
      this.prependToContainer(rendered);
    } else {
      this.prependToContainer(rendered);
      this.toggle();
    }
  }

  /**
   * Adds the rendered HTML to the container
   * @param {String} html Rendered HTML string.
   */
  prependToContainer(html) {
    // Convert the rendered HTML string to actual DOM nodes
    const tempContainer = document.createElement("div");
    tempContainer.innerHTML = html;
    while (tempContainer.firstChild) {
      this.containerTarget.prepend(tempContainer.firstChild);
    }
  }

  /**
   * Hides all the existing notifications on the page.
   */
  closeAll () {
    this.notificationTargets
      .filter(notification => !notification.classList.contains(this.transparentClass))
      .forEach(notification => {
        notification.classList.add(this.transparentClass, this.closedClass);
      });
  }

  /**
   * Closes the notification
   * @param {Event} event Click event.
   */
  close (event) {
    event.currentTarget.classList.add(this.transparentClass, this.closedClass);
  }

  /**
   * Removes all notifications that have been marked as closed from the DOM,
   * and displays any pending transparent notifications.
   * @param {Event} event Click event.
   */
  toggle () {
    this.notificationTargets
      .filter(notification => notification.classList.contains(this.closedClass))
      .forEach(notification => notification.remove());
    this.notificationTargets
      .forEach(notification => {
        setTimeout(() => notification.classList.remove(this.transparentClass), 10);
        setTimeout(() => notification.classList.add(this.transparentClass, this.closedClass), 2000);
      });
  }
}
