// Adds the Web Awesome theme stylesheet, thus it does not stop the first render.
//
// The file holds custom-property definitions only. It pulls in layers.css and a color palette, and
// neither native.css nor utilities.css, thus it styles no plain HTML element. Each consumer is a
// Web Awesome custom element, and such an element cannot render styled until the deferred bundle
// upgrades it. Thus the first paint does not need this file.
//
// ⚠️ This code reads the URL from the `<link rel="preload" as="style">` that the ERB writes in the
// head, because the name of the file has a hash from asset_hash. The preload also starts the
// download at the parse of the head.
//
// ⚠️ The element that this code adds has NO `data-turbo-track`. No rendered page contains it, thus
// Turbo keeps it through each navigation and never adds a second copy.
//
// ⚠️ Do NOT put the stylesheet in the head with a `media="print"` swap. Turbo puts the outerHTML
// of a `data-turbo-track="reload"` element in its signature, thus a change to an attribute at run
// time makes each navigation a full page load and stops the view transitions, with no message.

import { insertBeforeFirstStylesheet } from './utils';

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
  // Put it before the first stylesheet of the site. Thus each `wa-*` layer of Web Awesome sorts
  // before each layer of the site, and a rule in a site layer wins. stylesheets/base/_props.scss
  // needs that for `color-scheme` and for `--wa-color-brand-50`.
  insertBeforeFirstStylesheet(css);
}

loadWebAwesomeTheme();
