// Web Awesome's <wa-scroller> renders its scrollable region as
// `<div role="region" aria-orientation="...">`. `aria-orientation` is not a
// supported attribute on the `region` role, so axe-core (and Lighthouse /
// PageSpeed Insights' "accessibility tree is not well-formed" audit) flags it.
//
// The offending markup lives in the component's shadow DOM, so it can't be
// fixed from our own templates. Patch the element's `updated()` lifecycle hook
// to strip the attribute from the shadow root after every render. Matching on
// the `#content` selector (rather than the upstream chunk file) keeps this
// working across Web Awesome rebuilds and version bumps.
customElements.whenDefined('wa-scroller').then(() => {
  const WaScroller = customElements.get('wa-scroller');
  const originalUpdated = WaScroller.prototype.updated;
  WaScroller.prototype.updated = function (changedProperties) {
    originalUpdated?.call(this, changedProperties);
    this.shadowRoot
      ?.querySelector('#content')
      ?.removeAttribute('aria-orientation');
  };
});
