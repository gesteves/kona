import { beforeEach, describe, expect, it, vi } from 'vitest';

// Safari prints the images that already loaded, thus a lazy image is absent. The module changes each
// lazy image to eager when the reader starts a print.

const MODULE = '../../../source/javascripts/stimulus/lib/eager_print_images';

/** Keeps the change listener of `matchMedia('print')`, thus a test can call it. */
const stubPrintMedia = () => {
  const listeners = [];
  vi.stubGlobal('matchMedia', () => ({
    matches: false,
    addEventListener: (_event, handler) => listeners.push(handler),
  }));
  return listeners;
};

const images = () => [...document.querySelectorAll('img')];

beforeEach(() => {
  document.body.innerHTML = `
    <img id="a" loading="lazy">
    <img id="b" loading="lazy">
    <img id="c" loading="eager">
  `;
});

describe('eager_print_images', () => {
  it('switches lazy images to eager on beforeprint', async () => {
    stubPrintMedia();
    vi.resetModules();
    await import(MODULE);

    expect(images().map((i) => i.getAttribute('loading'))).toEqual([
      'lazy',
      'lazy',
      'eager',
    ]);

    window.dispatchEvent(new Event('beforeprint'));

    expect(images().map((i) => i.getAttribute('loading'))).toEqual([
      'eager',
      'eager',
      'eager',
    ]);
  });

  it('also switches them when the print media query starts matching', async () => {
    const listeners = stubPrintMedia();
    vi.resetModules();
    await import(MODULE);

    listeners.forEach((handler) => handler({ matches: true }));

    expect(images().map((i) => i.getAttribute('loading'))).toEqual([
      'eager',
      'eager',
      'eager',
    ]);
  });

  it('leaves images alone when the print media query stops matching', async () => {
    const listeners = stubPrintMedia();
    vi.resetModules();
    await import(MODULE);

    listeners.forEach((handler) => handler({ matches: false }));

    expect(images().map((i) => i.getAttribute('loading'))).toEqual([
      'lazy',
      'lazy',
      'eager',
    ]);
  });

  // ⚠️ Without this, one print makes each image on a long list load at once for the life of the
  // page. An image that was eager before the print stays eager.
  it('puts the images that it made eager back to lazy after the print', async () => {
    const listeners = stubPrintMedia();
    vi.resetModules();
    await import(MODULE);

    window.dispatchEvent(new Event('beforeprint'));
    window.dispatchEvent(new Event('afterprint'));
    expect(images().map((i) => i.getAttribute('loading'))).toEqual([
      'lazy',
      'lazy',
      'eager',
    ]);

    listeners.forEach((handler) => handler({ matches: true }));
    listeners.forEach((handler) => handler({ matches: false }));
    expect(images().map((i) => i.getAttribute('loading'))).toEqual([
      'lazy',
      'lazy',
      'eager',
    ]);
  });
});
