import { describe, expect, it, vi } from 'vitest';

// A shim for a Web Awesome bug: <wa-scroller> renders `<div role="region" aria-orientation="…">`,
// and aria-orientation isn't valid on the region role, so axe-core and Lighthouse flag it. The
// markup is in the component's shadow DOM, so it can't be fixed from our templates — the module
// monkey-patches the element class's `updated()` lifecycle hook instead.
//
// ⚠️ These tests run in ORDER and share one custom element registry (it belongs to the jsdom
// instance, so vi.resetModules() can't clear it, and re-defining a name throws). The
// "not yet defined" case therefore has to come first, while 'wa-scroller' is still unregistered.

const MODULE = '../../../source/javascripts/stimulus/lib/patch_scroller_aria';

/** An element stand-in exposing just the shadow root the patch reaches into. */
const scrollerWithContent = () => {
  const content = document.createElement('div');
  content.setAttribute('aria-orientation', 'horizontal');
  content.id = 'content';
  return { shadowRoot: { querySelector: () => content } };
};

describe('patch_scroller_aria', () => {
  it('waits for the element to be defined when it is not registered yet', async () => {
    // The defensive branch, for if the import order in index.js ever changes.
    vi.resetModules();
    expect(customElements.get('wa-scroller')).toBeUndefined();

    await import(MODULE);

    const updated = vi.fn();
    class WaScroller extends HTMLElement {}
    WaScroller.prototype.updated = updated;
    customElements.define('wa-scroller', WaScroller);
    await customElements.whenDefined('wa-scroller');
    await Promise.resolve();

    const scroller = scrollerWithContent();
    WaScroller.prototype.updated.call(scroller, 'changes');

    expect(
      scroller.shadowRoot.querySelector().hasAttribute('aria-orientation')
    ).toBe(false);
    expect(updated).toHaveBeenCalledWith('changes');
  });

  it('strips aria-orientation after every render, preserving the original hook', async () => {
    const WaScroller = customElements.get('wa-scroller');
    const original = vi.fn();
    WaScroller.prototype.updated = original; // undo the previous test's patch

    vi.resetModules();
    await import(MODULE);

    const scroller = scrollerWithContent();
    WaScroller.prototype.updated.call(scroller, 'changes');

    // Both halves matter: strip the attribute, and still run Lit's own updated() — dropping the
    // latter would break the component's rendering to fix an accessibility warning.
    expect(
      scroller.shadowRoot.querySelector().hasAttribute('aria-orientation')
    ).toBe(false);
    expect(original).toHaveBeenCalledTimes(1);
    expect(original.mock.instances[0]).toBe(scroller);
  });

  it('tolerates a component with no updated() hook of its own', async () => {
    const WaScroller = customElements.get('wa-scroller');
    delete WaScroller.prototype.updated;

    vi.resetModules();
    await import(MODULE);

    const scroller = scrollerWithContent();

    expect(() => WaScroller.prototype.updated.call(scroller)).not.toThrow();
  });

  it('tolerates a shadow root that has not rendered its content yet', async () => {
    const WaScroller = customElements.get('wa-scroller');
    WaScroller.prototype.updated = vi.fn();

    vi.resetModules();
    await import(MODULE);

    expect(() =>
      WaScroller.prototype.updated.call({ shadowRoot: null })
    ).not.toThrow();
    expect(() =>
      WaScroller.prototype.updated.call({
        shadowRoot: { querySelector: () => null },
      })
    ).not.toThrow();
  });
});
