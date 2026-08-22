import { describe, expect, it, vi } from 'vitest';

// A correction for a Web Awesome problem: <wa-scroller> renders
// `<div role="region" aria-orientation="…">`, and aria-orientation is not correct on the region
// role. Thus axe-core and Lighthouse report it. The markup is in the shadow DOM of the component,
// thus our templates cannot correct it. The module changes the `updated()` method of the element
// class instead.
//
// ⚠️ These tests run in ORDER and they share one custom element registry. That registry belongs to
// the jsdom instance, thus vi.resetModules() cannot empty it, and a second definition of a name
// raises. Thus the "not yet defined" example must come first, while 'wa-scroller' has no
// definition.

const MODULE = '../../../source/javascripts/stimulus/lib/patch_scroller_aria';

/** An element that replaces the true one. It gives only the shadow root that the patch uses. */
const scrollerWithContent = () => {
  const content = document.createElement('div');
  content.setAttribute('aria-orientation', 'horizontal');
  content.id = 'content';
  return { shadowRoot: { querySelector: () => content } };
};

describe('patch_scroller_aria', () => {
  it('waits for the element to be defined when it is not registered yet', async () => {
    // The safety code, for a change to the import order in index.js.
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

    // The two parts are both necessary: remove the attribute, and also call the updated() of Lit.
    // Without the second part, the component does not render correctly, and that is a large cost to
    // correct an accessibility warning.
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
