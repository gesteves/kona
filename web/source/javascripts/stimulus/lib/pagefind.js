// On-demand loader for Pagefind's Component UI, kept out of the <head> so it never blocks
// first paint. Three layers call the one memoized loadPagefind(), so nobody waits in practice
// and the layers can't double-inject: an idle preload after `load`, an intent prefetch on
// hover/focus of a Search trigger, and an awaited call in `search#open`.

const CSS_HREF = '/pagefind/pagefind-component-ui.css';
const JS_SRC = '/pagefind/pagefind-component-ui.js';

// Module scope, so it survives Turbo navigations along with the injected elements.
let loading;
let idleScheduled = false;

/**
 * Resolves once an element has finished loading, or failed to. Failure isn't exceptional:
 * `/pagefind/` doesn't exist in development, where search is a no-op by design.
 * @param {HTMLElement} element - The element to watch.
 * @returns {Promise<boolean>} Whether the element loaded successfully.
 */
function settleOnLoad(element) {
  return new Promise((resolve) => {
    element.addEventListener('load', () => resolve(true), { once: true });
    element.addEventListener('error', () => resolve(false), { once: true });
  });
}

/**
 * Injects Pagefind's stylesheet and component module, once per page lifetime.
 * @returns {Promise<boolean>} Resolves true once `<pagefind-modal>` is defined, or false
 *   if either asset failed to load (development, or a bad deploy).
 */
export function loadPagefind() {
  if (loading) return loading;

  const css = document.createElement('link');
  css.rel = 'stylesheet';
  css.href = CSS_HREF;
  const cssSettled = settleOnLoad(css);

  // Insert before the first existing stylesheet, never append: the dark-mode `--pf-*` remap
  // in stylesheets/components/_pagefind.scss beats Pagefind's own `:root` defaults only by
  // sitting later in source order. Appending renders the modal permanently light at night.
  document.head.insertBefore(
    css,
    document.head.querySelector('link[rel="stylesheet"]')
  );

  const js = document.createElement('script');
  js.type = 'module';
  js.src = JS_SRC;
  const jsSettled = settleOnLoad(js);
  // Neither element carries `data-turbo-track`: unmarked elements survive navigation, which is
  // what we want since no rendered page ever contains them.
  document.head.appendChild(js);

  loading = Promise.all([cssSettled, jsSettled]).then(([cssOk, jsOk]) => {
    // `whenDefined` for a script that 404'd never settles, which would hang `search#open`.
    if (!jsOk) return false;
    return customElements
      .whenDefined('pagefind-modal')
      .then(() => cssOk && jsOk);
  });

  return loading;
}

/**
 * Schedules the load for the first idle moment after the page has finished loading, so it
 * never competes with the critical path. Idempotent; safe to call on every `turbo:load`.
 */
export function preloadPagefindWhenIdle() {
  if (idleScheduled) return;
  idleScheduled = true;

  const schedule = () => {
    // Safari only gained requestIdleCallback in 17; fall back to a plain timeout.
    if (typeof window.requestIdleCallback === 'function') {
      window.requestIdleCallback(() => loadPagefind(), { timeout: 3000 });
    } else {
      setTimeout(() => loadPagefind(), 1000);
    }
  };

  if (document.readyState === 'complete') {
    schedule();
  } else {
    window.addEventListener('load', schedule, { once: true });
  }
}
