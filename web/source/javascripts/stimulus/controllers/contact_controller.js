import { Controller } from '@hotwired/stimulus';
import { sendNotification } from '../lib/utils';

const SUCCESS_MESSAGE = 'Thanks! Your message is on its way.';
const ERROR_MESSAGE =
  "Sorry, something went wrong and your message wasn't sent. Please try again.";

/**
 * Progressively enhances the contact form. The form is a real POST to /api/contact that works
 * without JS (native submit → server redirect to the Thank-You page). When this controller is
 * connected, it intercepts the submit, posts the same fields via fetch (asking for JSON so the
 * API answers 204/422 instead of redirecting), and reports the result with a toast — no
 * navigation. If it never loads, the native form submission still works.
 */
export default class extends Controller {
  static targets = ['submit'];

  /**
   * Cancels any in-flight submission so a late response can't fire a toast after a Turbo
   * navigation away from the page.
   */
  disconnect() {
    this.abortController?.abort();
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

    try {
      const response = await fetch(form.action, {
        method: 'POST',
        headers: { Accept: 'application/json' },
        // Same encoding as the native no-JS POST, so the API handles both identically.
        body: new URLSearchParams(new FormData(form)),
        signal: this.abortController.signal,
      });
      if (!response.ok) {
        throw new Error(`Unexpected response status: ${response.status}`);
      }
      form.reset();
      sendNotification(SUCCESS_MESSAGE, 'success');
    } catch (error) {
      if (error.name === 'AbortError') return; // navigated away — not a failure
      console.error('Contact form submission failed:', error);
      sendNotification(ERROR_MESSAGE, 'error');
    } finally {
      this.setSubmitting(false);
    }
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
