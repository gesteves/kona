import { Controller } from '@hotwired/stimulus';
import { replaceElement } from '../lib/utils';

/** The minimum time between two fetches of the same widget URL. A placeholder ignores it. */
const MIN_REFETCH_MS = 60_000;

// The time of the last fetch of each widget URL. This is at the module level, because the clock
// must stay after the element goes away and after the page renders again. The fragment from the
// fetch replaces the placeholder and disconnects the controller that did the fetch. A Turbo
// restoration visit renders a cached snapshot that contains the fragment, and it never gets that
// fragment again. The URL as the key also makes a loop of fetches impossible: a fragment that the
// code adds always finds its own time here.
const lastFetchAtByUrl = new Map();

/**
 * Gets an HTML fragment that the api renders, and puts it in the page.
 *
 * Three types of element run this controller, and two values show the type:
 * - `placeholder`: the skeleton on the web side. It has no real content, thus it always fetches,
 *   and it goes away on a failure.
 * - `static`: an element that the build renders with real content. It always fetches on connect,
 *   because the build content is older than any fragment. It keeps its content on a failure.
 * - Neither value: the api fragment. It fetches again only when its content is old, and it keeps
 *   its content on a failure.
 *
 * Refer to the HTML contract between the two apps in the root CLAUDE.md.
 */
export default class extends Controller {
  static values = {
    url: String,
    placeholder: Boolean,
    static: Boolean,
  };

  /**
   * Fetches immediately for a placeholder and for a static element, or when the content on the
   * page is old. A Turbo advance visit renders the static element from the build again, thus the
   * clock of an earlier visit cannot tell if this element is old.
   */
  connect() {
    if (this.placeholderValue || this.staticValue || this.isStale) {
      this.fetchAndUpdateContent();
    }
  }

  /** Stops each request in progress, thus a late response cannot change an element that is gone. */
  disconnect() {
    this.abortController?.abort();
  }

  /**
   * Gets old content again when the page becomes visible. This also covers a bfcache restore,
   * which has no Stimulus connect and disconnect, but which does change the document from hidden
   * to visible.
   */
  handleVisibilityChange() {
    if (document.visibilityState !== 'visible') return;
    if (!this.isStale) return;
    this.fetchAndUpdateContent();
  }

  /**
   * Tells if the content of this widget is old enough for a new fetch. A URL with no fetch counts
   * as old.
   * @returns {boolean} True when the last fetch was MIN_REFETCH_MS ago or more.
   */
  get isStale() {
    const lastFetchAt = lastFetchAtByUrl.get(this.urlValue);
    return !lastFetchAt || Date.now() - lastFetchAt >= MIN_REFETCH_MS;
  }

  /**
   * Gets the fragment from the URL in the configuration and puts it in the element.
   * @returns {Promise<void>} It resolves after the content changes, or after a failure that the
   *   code catches.
   */
  async fetchAndUpdateContent() {
    if (!this.hasUrlValue) return;

    // The code records the attempt, and not the result. Thus it does not get an endpoint that is
    // down again at each focus, and the fragment that it is about to add does not do a fetch
    // immediately.
    lastFetchAtByUrl.set(this.urlValue, Date.now());

    this.abortController?.abort();
    this.abortController = new AbortController();

    try {
      const response = await fetch(this.urlValue, {
        signal: this.abortController.signal,
      });
      if (!response.ok) {
        this.handleUnavailable();
        return;
      }
      const markup = (await response.text()).trim();
      if (markup.length > 0) {
        replaceElement(markup, this.element);
      } else {
        // An empty body is the "no data" answer from the API. Thus the widget goes away for a
        // placeholder and for a fragment.
        this.element.remove();
      }
    } catch (error) {
      if (error.name === 'AbortError') return;
      console.error('Error fetching content:', error);
      this.handleUnavailable();
    }
  }

  /**
   * Acts on a non-2xx status or a network error: it removes a placeholder, thus the page does not
   * keep a skeleton, but it does not change content that the page already shows.
   */
  handleUnavailable() {
    if (this.placeholderValue) {
      this.element.remove();
    }
  }
}
