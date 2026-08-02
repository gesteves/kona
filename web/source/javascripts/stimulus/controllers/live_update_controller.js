import { Controller } from '@hotwired/stimulus';
import { replaceElement } from '../lib/utils';

// Minimum gap between fetches of the same widget URL. It throttles every refetch trigger at
// once — tab refocus (without it, one alt-tab refetches all 5 home-page widgets) and Turbo
// back/forward restores. Well below the shortest widget data TTL (5 min), so it never withholds
// genuinely fresh data. Placeholders ignore it: they have nothing to show.
const MIN_REFETCH_MS = 60_000;

// When each widget URL was last fetched. Module-scoped, because "how old is what's on screen?"
// has to outlive both the element and the page render:
//   1. The fetched fragment REPLACES the placeholder, so the controller instance that did the
//      fetching disconnects and a brand-new one connects in its place.
//   2. Turbo Drive caches page snapshots. A back/forward "restoration visit" re-renders the
//      snapshot taken when the user left — one containing the already-swapped FRAGMENT, not the
//      placeholder — and, unlike a normal visit, never revalidates it against the network
//      (Visit#shouldIssueRequest returns false when a cached snapshot exists). Without this, a
//      restored widget would show whatever it showed when the user last left, indefinitely.
// Module scope is exactly the right lifetime: Turbo's snapshot cache is in-memory too, so both
// die with the document, and a fresh document always starts from server-rendered placeholders.
// Keying by URL rather than by element also makes a refetch loop structurally impossible — the
// fragment a fetch inserts always finds that fetch's own timestamp already recorded.
const lastFetchAtByUrl = new Map();

/**
 * Fetches a server-rendered HTML fragment from the api and swaps it into the page.
 *
 * Two kinds of element run this controller, and the difference is the `placeholder` value: the
 * web-side skeleton sets it (it has no real content, so it always fetches and collapses itself
 * if the fetch fails), and the api fragment that replaces it does not (it has real content, so
 * it only refetches when that content is stale and keeps it on a failed fetch).
 * See the root CLAUDE.md cross-app HTML contract.
 */
export default class extends Controller {
  static values = {
    url: String,
    placeholder: Boolean,
  };

  /**
   * A placeholder has nothing to show, so it always fetches. An element already showing real
   * content fetches only when that content has gone stale — which is what lets a restored Turbo
   * snapshot catch up instead of freezing at whatever it showed when the user left.
   */
  connect() {
    if (this.placeholderValue || this.isStale) {
      this.fetchAndUpdateContent();
    }
  }

  /**
   * Cancels any in-flight request so a late response can't mutate a detached element (after a
   * Turbo navigation, or once the fragment has already been swapped/removed).
   */
  disconnect() {
    this.abortController?.abort();
  }

  /**
   * Updates content when the page becomes visible, if it's stale. Also covers a bfcache restore,
   * where the page comes back without a Stimulus connect/disconnect cycle but the document does
   * transition hidden → visible.
   */
  handleVisibilityChange() {
    if (document.visibilityState !== 'visible') return;
    if (!this.isStale) return;
    this.fetchAndUpdateContent();
  }

  /**
   * Whether the content for this widget's URL is old enough to be worth refetching. Unknown
   * counts as stale — nothing in this document has fetched it yet.
   * @returns {Boolean} True when the last fetch attempt was long enough ago.
   */
  get isStale() {
    const lastFetchAt = lastFetchAtByUrl.get(this.urlValue);
    return !lastFetchAt || Date.now() - lastFetchAt >= MIN_REFETCH_MS;
  }

  /**
   * Fetches the fragment from the configured URL and swaps it into the element.
   * @async
   * @returns {Promise<void>} Resolves when the content is updated, or on a handled failure.
   */
  async fetchAndUpdateContent() {
    if (!this.hasUrlValue) return;

    // Record the attempt, not the outcome: a widget whose endpoint is down shouldn't retry on
    // every refocus, and the fragment this fetch is about to insert must see a fresh clock so it
    // doesn't immediately refetch itself. Tradeoff: a fetch aborted by a navigation still holds
    // the throttle, so in that narrow case content can be up to ~2× MIN_REFETCH_MS old. Not
    // worth a second clock to fix.
    lastFetchAtByUrl.set(this.urlValue, Date.now());

    this.abortController?.abort(); // supersede any in-flight request with this newer one
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
        // Empty body is the API's "no data" answer — an authoritative result, not a failure — so
        // the widget collapses whether or not it's still a placeholder.
        this.element.remove();
      }
    } catch (error) {
      if (error.name === 'AbortError') return; // superseded or disconnected — not a failure
      console.error('Error fetching content:', error);
      this.handleUnavailable();
    }
  }

  /**
   * Handles a failed fetch (non-2xx or network error). A placeholder is collapsed so it doesn't
   * sit stuck as a forever-skeleton; anything already showing real content keeps it, because a
   * transient blip must not destroy rendered content.
   */
  handleUnavailable() {
    if (this.placeholderValue) {
      this.element.remove();
    }
  }
}
