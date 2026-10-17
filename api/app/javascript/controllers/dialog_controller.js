import { Controller } from "@hotwired/stimulus";

/**
 * Closes a dialog before Turbo caches the page, and closes the mobile nav when the dialog opens.
 *
 * ⚠️ Turbo makes its snapshot of the DOM as it is. Thus an open confirmation dialog, a navigation
 * away, and a press of Back give a page with that dialog still open. A restoration visit never
 * renders again, thus nothing would close it. The flash controller exists for the same problem.
 *
 * ⚠️ A nav item with a dialog has no `data-drawer="close"`, because the drawer would stop its
 * click. Thus this controller closes the drawer. Refer to layouts/_admin_nav_item.html.erb.
 */
export default class extends Controller {
  connect() {
    this.close = () => this.element.removeAttribute("open");
    // ⚠️ The target check is necessary: a `wa-*` component in the dialog sends its own `wa-show`,
    // and that event bubbles.
    this.hideNavigation = (event) => {
      if (event.target === this.element) document.querySelector("wa-page")?.hideNavigation();
    };
    document.addEventListener("turbo:before-cache", this.close);
    this.element.addEventListener("wa-show", this.hideNavigation);
  }

  disconnect() {
    document.removeEventListener("turbo:before-cache", this.close);
    this.element.removeEventListener("wa-show", this.hideNavigation);
  }
}
