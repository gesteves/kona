// <wa-scroller> renders its region as `<div role="region" aria-orientation="...">`, which axe
// and Lighthouse flag — `aria-orientation` isn't valid on the `region` role. The markup is in
// shadow DOM, so it can't be fixed from our templates.
//
// TODO: Remove once the upstream bug is fixed and we've upgraded:
// https://github.com/shoelace-style/webawesome/issues/2364

/**
 * Patches `updated()` to strip the invalid attribute after every render.
 * Must run synchronously, before Lit's first render microtask — orientation never changes, so
 * `updated()` won't fire again to catch a late patch.
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
  // Fallback if import order ever changes; only safe before any instance has rendered.
  customElements
    .whenDefined('wa-scroller')
    .then(() => patchScrollerAria(customElements.get('wa-scroller')));
}
