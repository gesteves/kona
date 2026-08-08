import { beforeEach, describe, expect, it, vi } from 'vitest';

// Safari prints whatever has already loaded, so lazy images come out missing. The module flips
// them to eager when the reader heads into print.

const MODULE = '../../../source/javascripts/stimulus/lib/eager_print_images';

/** Captures the `matchMedia('print')` change listener so tests can fire it. */
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
});
