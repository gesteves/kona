// <wa-scroller> renders its area as `<div role="region" aria-orientation="...">`, and axe and
// Lighthouse report that, because `aria-orientation` is not correct on the `region` role. The markup
// is in the shadow DOM, thus our templates cannot correct it.
//
// TODO: Remove this file after the other project corrects the problem and we install the new
// version: https://github.com/shoelace-style/webawesome/issues/2364

/**
 * Changes `updated()` to remove the incorrect attribute after each render.
 * This must run immediately, before the first render microtask of Lit. The orientation never
 * changes, thus `updated()` does not run again and a late change would do nothing.
 */
function patchScrollerAria(WaScroller) {
  if (!WaScroller) {
    return;
  }
  const originalUpdated = WaScroller.prototype.updated;
  WaScroller.prototype.updated = function (changedProperties) {
    originalUpdated?.call(this, changedProperties);
    this.shadowRoot
      ?.querySelector('#content')
      ?.removeAttribute('aria-orientation');
  };
}

const WaScroller = customElements.get('wa-scroller');
if (WaScroller) {
  patchScrollerAria(WaScroller);
} else {
  // This applies if the import order changes. It is safe only before an instance renders.
  customElements
    .whenDefined('wa-scroller')
    .then(() => patchScrollerAria(customElements.get('wa-scroller')));
}
