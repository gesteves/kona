import { Controller } from '@hotwired/stimulus';
import { replaceElement } from '../lib/utils';

/** Minimum gap between fetches of the same widget URL. Placeholders ignore it. */
const MIN_REFETCH_MS = 60_000;

// When each widget URL was last fetched. Module-scoped because the clock has to outlive both
// the element (the fetched fragment replaces the placeholder, disconnecting the controller
// that fetched it) and the page render (a Turbo restoration visit re-renders a cached snapshot
// containing the already-swapped fragment and never revalidates it). Keying by URL also makes
// a refetch loop impossible: an inserted fragment always finds its own timestamp recorded.
const lastFetchAtByUrl = new Map();

/**
 * Fetches a server-rendered HTML fragment from the api and swaps it into the page.
 *
 * The `placeholder` value distinguishes the two kinds of element that run this controller: the
 * web-side skeleton sets it (no real content, so it always fetches and collapses on failure);
 * the api fragment that replaces it does not (refetches only when stale, keeps its content on
 * failure). See the root CLAUDE.md cross-app HTML contract.
 */
export default class extends Controller {
  static values = {
    url: String,
    placeholder: Boolean,
  };

  /** Fetches immediately for a placeholder, or when rendered content has gone stale. */
  connect() {
    if (this.placeholderValue || this.isStale) {
      this.fetchAndUpdateContent();
    }
  }

  /** Cancels any in-flight request so a late response can't mutate a detached element. */
  disconnect() {
    this.abortController?.abort();
  }

  /**
   * Refetches stale content when the page becomes visible. Also covers a bfcache restore, which
   * has no Stimulus connect/disconnect cycle but does transition the document hidden → visible.
   */
  handleVisibilityChange() {
    if (document.visibilityState !== 'visible') return;
    if (!this.isStale) return;
    this.fetchAndUpdateContent();
  }

  /**
   * Whether this widget's content is old enough to refetch. Never-fetched counts as stale.
   * @returns {Boolean} True when the last fetch attempt was at least MIN_REFETCH_MS ago.
   */
  get isStale() {
    const lastFetchAt = lastFetchAtByUrl.get(this.urlValue);
    return !lastFetchAt || Date.now() - lastFetchAt >= MIN_REFETCH_MS;
  }

  /**
   * Fetches the fragment from the configured URL and swaps it into the element.
   * @returns {Promise<void>} Resolves when the content is updated, or on a handled failure.
   */
  async fetchAndUpdateContent() {
    if (!this.hasUrlValue) return;

    // Records the attempt, not the outcome, so a down endpoint isn't retried on every refocus
    // and the fragment about to be inserted doesn't immediately refetch itself.
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
        // An empty body is the API's authoritative "no data" answer, so the widget collapses
        // whether or not it's still a placeholder.
        this.element.remove();
      }
    } catch (error) {
      if (error.name === 'AbortError') return;
      console.error('Error fetching content:', error);
      this.handleUnavailable();
    }
  }

  /**
   * Handles a non-2xx or network error: collapses a placeholder so it isn't stuck as a
   * skeleton, but leaves already-rendered content alone.
   */
  handleUnavailable() {
    if (this.placeholderValue) {
      this.element.remove();
    }
  }
}
