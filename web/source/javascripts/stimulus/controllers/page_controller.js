import { trackPageView } from '../lib/analytics';
import { Controller } from '@hotwired/stimulus';

/** The id of the live region and of the main landmark, both in layouts/layout.erb. */
const ANNOUNCER_ID = 'route-announcer';
const MAIN_ID = 'main-content';

// The wait between the empty region and the new text. A screen reader must see a change, thus the
// two writes cannot be in the same task.
const ANNOUNCE_DELAY_MS = 50;

/** The Turbo lifecycle methods of the page. */
export default class extends Controller {
  connect() {
    // `turbo:load` also runs for the first render of the document. The browser announces that page
    // itself, thus the code counts this load and announces nothing.
    this.hasLoaded = false;
  }

  /** Records a page view and announces the new page. `turbo:load` calls it. */
  load() {
    trackPageView();

    if (!this.hasLoaded) {
      this.hasLoaded = true;
      return;
    }

    this.announcePage();
    this.focusMain();
  }

  /**
   * Writes the title of the page into the live region.
   *
   * ⚠️ Turbo Drive replaces the body only, thus a navigation changes the full page and no element
   * gets the focus. A screen reader then gives no message that the page changed. The region is
   * `data-turbo-permanent`, because a NEW element that already holds its text does not announce.
   * The code empties it and writes the text after a wait, for the same reason.
   *
   * ⚠️ Use a timer and NOT requestAnimationFrame. A browser does not run a frame callback for a
   * page that is not visible, thus the message would never arrive for a navigation in a background
   * tab. A timer runs in both conditions.
   */
  announcePage() {
    const region = document.getElementById(ANNOUNCER_ID);
    if (!region) {
      return;
    }
    const title = document.title;
    region.textContent = '';
    setTimeout(() => {
      region.textContent = title;
    }, ANNOUNCE_DELAY_MS);
  }

  /**
   * Moves the focus to the main landmark, thus the keyboard and the screen reader continue at the
   * start of the new content. The header is still one Shift-Tab away.
   *
   * ⚠️ `preventScroll` is necessary. Turbo already set the scroll position, and a restoration visit
   * gives back the position of the reader. A focus without this flag would move the page again.
   */
  focusMain() {
    document.getElementById(MAIN_ID)?.focus({ preventScroll: true });
  }

  /**
   * Removes each toast from the stack before Turbo caches the page. `turbo:before-cache` calls it.
   * The countdown of a `<wa-toast-item>` stops when Turbo disconnects the DOM, and it never starts
   * again. Thus a toast in a snapshot appears again, and it does not move, the next time that the
   * stack opens.
   */
  clearNotifications() {
    document.getElementById('notifications')?.replaceChildren();
  }
}
