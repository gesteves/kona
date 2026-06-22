import { Controller } from '@hotwired/stimulus';
import { replaceElement } from '../lib/utils';

// Minimum gap between visibilitychange-triggered refetches. Without it, every tab refocus
// refetches every widget at once (5 on the home page); this collapses rapid alt-tab storms.
// Well below the shortest widget data TTL (5 min), so it never withholds genuinely fresh data.
const MIN_VISIBILITY_REFETCH_MS = 60_000;

/**
 * Fetches a server-rendered HTML fragment and swaps it into the page, replacing a placeholder
 * skeleton; refreshes on tab focus. See the root CLAUDE.md cross-app HTML contract.
 */
export default class extends Controller {
  static values = {
    url: String,
    fetchOnConnect: Boolean,
  };

  /**
   * Fetches content on connect when opted in (e.g. for markup served by an external API
   * rather than server-rendered into the page).
   */
  connect() {
    if (this.fetchOnConnectValue) {
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
   * Updates content when the page becomes visible.
   */
  handleVisibilityChange() {
    if (document.visibilityState !== 'visible') return;
    // Skip refocus refetches that arrive too soon after the last fetch attempt.
    if (
      this.lastFetchAt &&
      Date.now() - this.lastFetchAt < MIN_VISIBILITY_REFETCH_MS
    ) {
      return;
    }
    this.fetchAndUpdateContent();
  }

  /**
   * Fetches the fragment from the configured URL and swaps it into the element.
   * @async
   * @returns {Promise<void>} Resolves when the content is updated, or on a handled failure.
   */
  async fetchAndUpdateContent() {
    if (!this.hasUrlValue) return;

    this.lastFetchAt = Date.now(); // mark the attempt so handleVisibilityChange can throttle refocus refetches

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
        // Empty body is the API's "no data" answer; collapse the widget.
        this.element.remove();
      }
    } catch (error) {
      if (error.name === 'AbortError') return; // superseded or disconnected — not a failure
      console.error('Error fetching content:', error);
      this.handleUnavailable();
    }
  }

  /**
   * Handles a failed fetch (non-2xx or network error). On the initial skeleton load
   * (fetchOnConnect=true) the placeholder is collapsed so it doesn't sit stuck; but once real
   * content is rendered (a visibilitychange refresh), a transient blip must not destroy it.
   */
  handleUnavailable() {
    if (this.fetchOnConnectValue) {
      this.element.remove();
    }
  }
}
