import { Controller } from '@hotwired/stimulus';
import { prependToElement } from '../lib/utils';
import Handlebars from 'handlebars';

/**
 * Controls the notifications.
 * @extends Controller
 */
export default class extends Controller {
  static classes = ['transparent', 'closed'];
  static targets = ['container', 'notification', 'template'];

  connect() {
    this.toggle();
  }

  /**
   * Adds a new notification to the notifications container
   * @param {Event} event Custom `notify` event.
   */
  add(event) {
    const status = event.detail.status;
    const message = event.detail.message;
    // Get the Handlebars template from the target element
    const template = this.templateTarget.innerHTML;
    // Compile the Handlebars template
    const compiledTemplate = Handlebars.compile(template);
    // Render the compiled template with data
    const rendered = compiledTemplate({
      message: message,
      status: status,
      showSuccessIcon: this.showSuccessIcon(status),
      showWarningIcon: !this.showSuccessIcon(status),
    });

    if (this.hasNotificationTarget) {
      this.closeAll();
      prependToElement(rendered, this.containerTarget);
    } else {
      prependToElement(rendered, this.containerTarget);
      this.toggle();
    }
  }

  /**
   * Checks if we should show the success icon.
   * @param {String} icon The icon name.
   * @returns {Boolean} True if we should show the success icon.
   */
  showSuccessIcon(status) {
    return status === 'success';
  }

  /**
   * Hides all the existing notifications on the page.
   */
  closeAll() {
    this.notificationTargets
      .filter(
        (notification) =>
          !notification.classList.contains(this.transparentClass)
      )
      .forEach((notification) => {
        notification.classList.add(this.transparentClass, this.closedClass);
      });
  }

  /**
   * Closes the notification
   * @param {Event} event Click event.
   */
  close(event) {
    event.currentTarget.classList.add(this.transparentClass, this.closedClass);
  }

  /**
   * Removes all notifications that have been marked as closed from the DOM,
   * and displays any pending transparent notifications.
   */
  toggle() {
    this.notificationTargets
      .filter((notification) =>
        notification.classList.contains(this.closedClass)
      )
      .forEach((notification) => notification.remove());
    this.notificationTargets.forEach((notification) => {
      setTimeout(
        () => notification.classList.remove(this.transparentClass),
        10
      );
      setTimeout(
        () =>
          notification.classList.add(this.transparentClass, this.closedClass),
        2000
      );
    });
  }
}
