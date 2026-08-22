import { Controller } from '@hotwired/stimulus';
import { sendNotification } from '../lib/utils';

const SUCCESS_MESSAGE = 'Thanks! Your message is on its way.';
const ERROR_MESSAGE =
  "Sorry, something went wrong and your message wasn't sent. Please try again.";

// This uses the explicit-render mode. Thus connect and disconnect control the life of the widget,
// and the widget continues through a Turbo navigation. The `onload` parameter of Turnstile says
// when it is ready, because turnstile.ready() raises for a script that the page loads at
// runtime.
const TURNSTILE_ONLOAD = '__konaTurnstileOnload';
const TURNSTILE_SRC = `https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=${TURNSTILE_ONLOAD}`;

/**
 * Adds behavior to the contact form. The form is a true POST to /api/contact that works with no
 * JavaScript: a native submit, then a redirect to the Thank-You page. This code takes the submit,
 * posts the same fields with fetch and asks for JSON (204 or 422), and shows the result in a toast
 * instead of a navigation.
 *
 * With a sitekey in the configuration, it also renders a Cloudflare Turnstile widget and sends its
 * token. The API checks that token on the server, on the JavaScript path.
 */
export default class extends Controller {
  static targets = ['submit', 'turnstile'];
  static values = { siteKey: String };

  /** Renders the Turnstile widget, if the configuration has one, after its script is ready. */
  connect() {
    if (!this.siteKeyValue || !this.hasTurnstileTarget) return;
    this.loadTurnstile()
      .then(() => {
        // A Turbo navigation away from /contact can occur between the script request and its
        // result. Without this check, the widget renders into an element that is not in the
        // document, and the code sets widgetId after disconnect() ran. Thus nothing removes it.
        if (!this.element.isConnected) return;
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
   * Stops a submission in progress, thus a late response cannot show a toast after a Turbo
   * navigation. It also removes the Turnstile widget.
   */
  disconnect() {
    this.abortController?.abort();
    if (this.widgetId && window.turnstile) {
      window.turnstile.remove(this.widgetId);
      this.widgetId = null;
    }
  }

  /**
   * Submits the form with fetch, and not with a native navigation.
   * @param {SubmitEvent} event The submit event of the form.
   */
  async submit(event) {
    event.preventDefault();
    const form = this.element;

    this.abortController?.abort();
    this.abortController = new AbortController();
    this.setSubmitting(true);

    // This uses the same encoding as the native POST with no JavaScript, thus the API reads both
    // in the same way. With the explicit render, the Turnstile token is not in a hidden field.
    // Thus the code adds it here.
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
      // A 422 means that the API refuses the input. It is not a failure. A message that says
      // "something went wrong, please try again" would be incorrect, and the visitor could do
      // nothing with it: the same input fails in the same way, and resetTurnstile() already used
      // their challenge. The form keeps its content, thus the visitor can correct the field and
      // does not type the message again.
      if (response.status === 422) {
        this.resetTurnstile();
        sendNotification(await this.errorMessage(response), 'error');
        return;
      }
      if (!response.ok) {
        throw new Error(`Unexpected response status: ${response.status}`);
      }
      form.reset();
      this.resetTurnstile();
      sendNotification(SUCCESS_MESSAGE, 'success');
    } catch (error) {
      if (error.name === 'AbortError') return;
      console.error('Contact form submission failed:', error);
      this.resetTurnstile();
      sendNotification(ERROR_MESSAGE, 'error');
    } finally {
      this.setSubmitting(false);
    }
  }

  /**
   * The validation message from the API. If the body does not have the JSON shape that this code
   * needs, it gives the general message.
   * @param {Response} response A 422 response.
   * @returns {Promise<string>}
   */
  async errorMessage(response) {
    try {
      const { error } = await response.json();
      return typeof error === 'string' && error.trim() ? error : ERROR_MESSAGE;
    } catch {
      return ERROR_MESSAGE;
    }
  }

  /** Resets the widget, thus the next submit gets a new token. A Turnstile token works one time. */
  resetTurnstile() {
    this.turnstileToken = null;
    if (this.widgetId && window.turnstile) {
      window.turnstile.reset(this.widgetId);
    }
  }

  /**
   * Loads the Turnstile script one time for each page, and each controller instance uses it. The
   * `onload` callback of Turnstile resolves the promise, when window.turnstile is ready. The load
   * event of the script does not.
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
        script.onerror = (error) => {
          // Remove the stored value, thus a later visit tries again. A promise with an error in
          // the cache would stop the challenge for the rest of the life of the page after one
          // small network problem.
          window.__konaTurnstileLoad = null;
          script.remove();
          reject(error);
        };
        document.head.appendChild(script);
      });
    }
    return window.__konaTurnstileLoad;
  }

  /**
   * Shows the state of the submission on the submit button: a spinner, and the button is off. It
   * does nothing if the button is not a target, thus the form still works.
   * @param {boolean} isSubmitting True if a submission is in progress.
   */
  setSubmitting(isSubmitting) {
    if (!this.hasSubmitTarget) return;
    this.submitTarget.loading = isSubmitting;
    this.submitTarget.disabled = isSubmitting;
  }
}
