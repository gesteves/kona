// Adds the Web Awesome theme stylesheet, thus it does not stop the first render.
//
// The file holds custom-property definitions only. It pulls in layers.css and a color palette, and
// neither native.css nor utilities.css, thus it styles no plain HTML element. Each consumer is a
// Web Awesome custom element, and such an element cannot render styled until the deferred bundle
// upgrades it. Thus the first paint does not need this file.
//
// ⚠️ The ERB writes a `<link rel="preload" as="style">` in the head, and this code reads the URL
// from it. The name of the file has a hash from asset_hash, thus the JavaScript cannot write it.
// The preload also starts the download at the parse of the head, thus this stylesheet is usually
// already in the cache when the code adds it.
//
// ⚠️ The element that this code adds has NO `data-turbo-track`. That is correct and necessary: no
// rendered page contains this element, thus Turbo keeps it through each navigation and never adds a
// second copy. Do NOT move the stylesheet back into the head with a `media="print"` swap. Turbo
// puts the outerHTML of an element with `data-turbo-track="reload"` in its signature of the tracked
// elements, thus a change to an attribute at run time makes each navigation a full page load and
// stops the view transitions, with no message. That was tried and reverted.

const PRELOAD_SELECTOR = 'link[rel="preload"][as="style"][data-wa-theme]';

let added = false;

/** Adds the theme stylesheet one time for the life of the page. */
export function loadWebAwesomeTheme() {
  if (added) {
    return;
  }
  const preload = document.head.querySelector(PRELOAD_SELECTOR);
  // Read the attribute, and not the `href` property: the property gives the absolute form, and the
  // element must carry the same URL that the build wrote.
  const href = preload && preload.getAttribute('href');
  if (!href) {
    return;
  }
  added = true;

  const css = document.createElement('link');
  css.rel = 'stylesheet';
  css.setAttribute('href', href);
  // Put it before the first stylesheet of the site. The theme gives the default values of the
  // `--wa-*` tokens, and stylesheets/components/_toast.scss and _skeleton.scss replace some of
  // them. Those files win only when they are later in the source order.
  document.head.insertBefore(
    css,
    document.head.querySelector('link[rel="stylesheet"]')
  );
}

loadWebAwesomeTheme();
