// The on-demand loader for the Pagefind Component UI. It is not in the <head>, thus it never
// delays the first paint. Three parts of the app call the one loadPagefind(), which keeps its
// result. Thus nobody waits in practice, and the three parts cannot add the elements two times: a
// load at the first idle moment after `load`, a load when the pointer or the focus goes to a Search
// button, and a call in `search#open` that waits for the result.

const CSS_HREF = '/pagefind/pagefind-component-ui.css';
const JS_SRC = '/pagefind/pagefind-component-ui.js';

// This is at the module level, thus it stays through a Turbo navigation, with the elements that
// the code adds.
let loading;
let idleScheduled = false;

/**
 * Resolves after an element loads or fails to load. A failure is not unusual: `/pagefind/` does not
 * exist in development, where the search does nothing, on purpose.
 * @param {HTMLElement} element - The element to watch.
 * @returns {Promise<boolean>} True if the element loaded.
 */
function settleOnLoad(element) {
  return new Promise((resolve) => {
    element.addEventListener('load', () => resolve(true), { once: true });
    element.addEventListener('error', () => resolve(false), { once: true });
  });
}

/**
 * Adds the Pagefind stylesheet and component module, one time for the life of the page.
 * @returns {Promise<boolean>} True after `<pagefind-modal>` exists, or false if one of the two
 *   files did not load, which occurs in development and after a bad deploy.
 */
export function loadPagefind() {
  if (loading) return loading;

  const css = document.createElement('link');
  css.rel = 'stylesheet';
  css.href = CSS_HREF;
  const cssSettled = settleOnLoad(css);

  // Put this before the first stylesheet, and never at the end. The dark-mode `--pf-*` values in
  // stylesheets/components/_pagefind.scss win over the `:root` defaults of Pagefind only because
  // they are later in the source order. At the end, the modal stays light at night.
  document.head.insertBefore(
    css,
    document.head.querySelector('link[rel="stylesheet"]')
  );

  const js = document.createElement('script');
  js.type = 'module';
  js.src = JS_SRC;
  const jsSettled = settleOnLoad(js);
  // The two elements have no `data-turbo-track`. An element with no such mark stays through a
  // navigation, which is correct here, because no rendered page contains them.
  document.head.appendChild(js);

  // A load that fails forgets its result and removes its elements. Thus the next call, from a
  // pointer, a focus, or `search#open`, loads again, and one short network problem does not stop
  // the search for the life of the page.
  const forget = () => {
    loading = null;
    css.remove();
    js.remove();
    return false;
  };

  loading = Promise.all([cssSettled, jsSettled]).then(([cssOk, jsOk]) => {
    // `whenDefined` for a script that gave a 404 never resolves, and that would stop
    // `search#open`.
    if (!jsOk) return forget();
    return customElements
      .whenDefined('pagefind-modal')
      .then(() => (cssOk ? true : forget()));
  });

  return loading;
}

/**
 * Starts the load at the first idle moment after the page loads, thus it never uses time that the
 * important work needs. You can call it more than one time, and it is safe at each `turbo:load`.
 */
export function preloadPagefindWhenIdle() {
  if (idleScheduled) return;
  idleScheduled = true;

  const schedule = () => {
    // Safari has requestIdleCallback only from version 17. Use a plain timeout for the older
    // versions.
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
