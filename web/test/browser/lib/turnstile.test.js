import { describe, expect, it } from 'vitest';
import { loadTurnstile } from '../../../source/javascripts/stimulus/lib/turnstile';

// The loader keeps its promise on `window`, and test/browser/setup.js removes that state after
// each test. test/browser/controllers/contact.test.js covers the render of the widget.

const script = () => document.querySelector('script[src*="turnstile"]');

describe('loadTurnstile', () => {
  it('resolves at once, and adds no script, when Turnstile is already there', async () => {
    window.turnstile = {};

    await expect(loadTurnstile()).resolves.toBeUndefined();
    expect(script()).toBeNull();
  });

  it('adds one script for the explicit render, and resolves at its onload callback', async () => {
    const loaded = loadTurnstile();

    expect(loadTurnstile()).toBe(loaded);
    expect(document.querySelectorAll('script[src*="turnstile"]')).toHaveLength(
      1
    );
    expect(script().src).toContain('render=explicit');
    expect(script().src).toContain('onload=__konaTurnstileOnload');

    window.__konaTurnstileOnload();
    await expect(loaded).resolves.toBeUndefined();
  });

  // ⚠️ A promise with an error must not stay: one short network problem would stop the challenge
  // for the life of the page.
  it('forgets a load that fails, thus the next call tries again', async () => {
    const failed = loadTurnstile();
    script().dispatchEvent(new Event('error'));

    await expect(failed).rejects.toBeDefined();
    expect(script()).toBeNull();

    expect(loadTurnstile()).not.toBe(failed);
    expect(script()).not.toBeNull();
  });
});
