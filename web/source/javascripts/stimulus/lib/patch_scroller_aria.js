// Web Awesome's <wa-scroller> renders its scrollable region as
// `<div role="region" aria-orientation="...">`. `aria-orientation` is not a
// supported attribute on the `region` role, so axe-core (and Lighthouse /
// PageSpeed Insights' "accessibility tree is not well-formed" + "[aria-*]
// attributes do not match their roles" audits) flags it.
//
// The offending markup lives in the component's shadow DOM, so it can't be
// fixed from our own templates. Patch the element's `updated()` lifecycle hook
// to strip the attribute from the shadow root after every render. Matching on
// the `#content` selector (rather than the upstream chunk file) keeps this
// working across Web Awesome rebuilds and version bumps.
//
// The patch must be applied synchronously: `scroller.js` is imported just
// before this module, so `customElements.define('wa-scroller', …)` has already
// run and the class is available now. Patching the prototype here — before the
// current synchronous task yields — guarantees it's in place before Lit's first
// render microtask, which is the element's only render (orientation never
// changes, so `updated()` won't fire again to catch a late patch).
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
  // Defensive fallback if import order ever changes and the element isn't
  // defined yet — only safe before any instance has rendered.
  customElements
    .whenDefined('wa-scroller')
    .then(() => patchScrollerAria(customElements.get('wa-scroller')));
}
