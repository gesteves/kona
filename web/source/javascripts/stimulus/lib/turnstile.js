// The on-demand loader for Cloudflare Turnstile, for the contact form.
//
// This uses the explicit-render mode. Thus the controller controls the life of the widget, and the
// widget continues through a Turbo navigation. The `onload` parameter of Turnstile says when it is
// ready, because turnstile.ready() raises for a script that the page loads at runtime.
const ONLOAD = '__konaTurnstileOnload';
const SRC = `https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=${ONLOAD}`;

/**
 * Loads the Turnstile script one time for each page, and each controller instance uses it. The
 * `onload` callback of Turnstile resolves the promise, when window.turnstile is ready. The load
 * event of the script does not.
 * @returns {Promise<void>}
 */
export function loadTurnstile() {
  if (window.turnstile) return Promise.resolve();
  if (!window.__konaTurnstileLoad) {
    window.__konaTurnstileLoad = new Promise((resolve, reject) => {
      window[ONLOAD] = resolve;
      const script = document.createElement('script');
      script.src = SRC;
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
