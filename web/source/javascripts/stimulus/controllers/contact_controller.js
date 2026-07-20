import { Controller } from '@hotwired/stimulus';
import { sendNotification } from '../lib/utils';

const SUCCESS_MESSAGE = 'Thanks! Your message is on its way.';
const ERROR_MESSAGE =
  "Sorry, something went wrong and your message wasn't sent. Please try again.";

// Explicit-render mode so the widget's lifecycle is driven from connect/disconnect (Turbo-safe)
// rather than an auto-scan that wouldn't re-run on Turbo navigation. We load api.js dynamically,
// so we must NOT use turnstile.ready() (it throws on an async/deferred script); Turnstile's own
// `onload` callback param is the supported way to know when it's ready.
const TURNSTILE_ONLOAD = '__konaTurnstileOnload';
const TURNSTILE_SRC = `https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=${TURNSTILE_ONLOAD}`;

/**
 * Progressively enhances the contact form. The form is a real POST to /api/contact that works
 * without JS (native submit → server redirect to the Thank-You page). When this controller is
 * connected, it intercepts the submit, posts the same fields via fetch (asking for JSON so the
 * API answers 204/422 instead of redirecting), and reports the result with a toast — no
 * navigation. If it never loads, the native form submission still works.
 *
 * When a Turnstile sitekey is configured, it also renders a Cloudflare Turnstile widget and
 * includes its token with the submission (the API verifies it server-side on the JS path).
 */
export default class extends Controller {
  static targets = ['submit', 'turnstile'];
  static values = { siteKey: String };

  /**
   * Renders the Turnstile widget (when configured) once its script is loaded.
   */
  connect() {
    if (!this.siteKeyValue || !this.hasTurnstileTarget) return;
    this.loadTurnstile()
      .then(() => {
        // Turnstile is ready here (onload fired), so render directly — no turnstile.ready().
        this.widgetId = window.turnstile.render(this.turnstileTarget, {
          sitekey: this.siteKeyValue,
          callback: (token) => {
            this.turnstileToken = token;
          },
          'error-callback': () => {
            this.turnstileToken = null;
          },
          'expired-callback': () => {
            this.turnstileToken = null;
          },
        });
      })
      .catch((error) => console.error('Turnstile failed to load:', error));
  }

  /**
   * Cancels any in-flight submission (so a late response can't fire a toast after a Turbo
   * navigation) and tears down the Turnstile widget.
   */
  disconnect() {
    this.abortController?.abort();
    if (this.widgetId && window.turnstile) {
      window.turnstile.remove(this.widgetId);
      this.widgetId = null;
    }
  }

  /**
   * Submits the form via fetch instead of a native navigation.
   * @param {SubmitEvent} event The form submit event.
   */
  async submit(event) {
    event.preventDefault();
    const form = this.element;

    this.abortController?.abort();
    this.abortController = new AbortController();
    this.setSubmitting(true);

    // Same encoding as the native no-JS POST, so the API handles both identically. The Turnstile
    // token (explicit render → not in a hidden field) is added here when present.
    const body = new URLSearchParams(new FormData(form));
    if (this.turnstileToken) {
      body.set('cf-turnstile-response', this.turnstileToken);
    }

    try {
      const response = await fetch(form.action, {
        method: 'POST',
        headers: { Accept: 'application/json' },
        body,
        signal: this.abortController.signal,
      });
      if (!response.ok) {
        throw new Error(`Unexpected response status: ${response.status}`);
      }
      form.reset();
      this.resetTurnstile();
      sendNotification(SUCCESS_MESSAGE, 'success');
    } catch (error) {
      if (error.name === 'AbortError') return; // navigated away — not a failure
      console.error('Contact form submission failed:', error);
      this.resetTurnstile();
      sendNotification(ERROR_MESSAGE, 'error');
    } finally {
      this.setSubmitting(false);
    }
  }

  /**
   * Resets the Turnstile widget so the next submit gets a fresh token (tokens are single-use).
   */
  resetTurnstile() {
    this.turnstileToken = null;
    if (this.widgetId && window.turnstile) {
      window.turnstile.reset(this.widgetId);
    }
  }

  /**
   * Loads the Turnstile script once per page, shared across controller instances. Resolves via
   * Turnstile's `onload` callback (when window.turnstile is ready), not the script's load event.
   * @returns {Promise<void>}
   */
  loadTurnstile() {
    if (window.turnstile) return Promise.resolve();
    if (!window.__konaTurnstileLoad) {
      window.__konaTurnstileLoad = new Promise((resolve, reject) => {
        window[TURNSTILE_ONLOAD] = resolve;
        const script = document.createElement('script');
        script.src = TURNSTILE_SRC;
        script.async = true;
        script.onerror = reject;
        document.head.appendChild(script);
      });
    }
    return window.__konaTurnstileLoad;
  }

  /**
   * Reflects the in-flight state on the submit button (spinner + disabled). No-ops when the
   * button isn't wired as a target, so the form still works.
   * @param {boolean} isSubmitting Whether a submission is in flight.
   */
  setSubmitting(isSubmitting) {
    if (!this.hasSubmitTarget) return;
    this.submitTarget.loading = isSubmitting;
    this.submitTarget.disabled = isSubmitting;
  }
}
