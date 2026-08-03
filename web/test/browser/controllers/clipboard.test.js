import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import ClipboardController from '../../../source/javascripts/stimulus/controllers/clipboard_controller';
import * as analytics from '../../../source/javascripts/stimulus/lib/analytics';
import { flushDom, mount, stubProperty } from '../helpers';

vi.mock('../../../source/javascripts/stimulus/lib/analytics', () => ({
  trackEvent: vi.fn(),
}));

const MARKUP = `
  <a href="/2026/01/01/hello" data-controller="clipboard"
     data-action="clipboard#copy" data-clipboard-hidden-class="hidden">
    <span data-clipboard-target="link"></span>
    <span data-clipboard-target="check" class="hidden"></span>
  </a>
`;

let toast;

/** The last message handed to the <wa-toast> stack, with its variant. */
const lastToast = () => {
  const call = toast.create.mock.calls.at(-1);
  return call && { message: call[0], variant: call[1].variant };
};

const linkIcon = () => document.querySelector('[data-clipboard-target="link"]');
const checkIcon = () =>
  document.querySelector('[data-clipboard-target="check"]');

beforeEach(() => {
  toast = document.createElement('wa-toast');
  toast.create = vi.fn();
});

afterEach(() => {
  vi.useRealTimers();
});

/** Mounts the controller with a clipboard whose writeText resolves or rejects. */
const mountClipboard = async (writeText, markup = MARKUP) => {
  if (writeText) stubProperty(navigator, 'clipboard', { writeText });
  const mounted = await mount('clipboard', ClipboardController, markup);
  document.body.appendChild(toast); // after mount: mount() writes document.body itself
  return mounted;
};

describe('clipboard controller', () => {
  it('copies the permalink as an absolute URL and reports success', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    const { element } = await mountClipboard(writeText);

    element.click();
    await flushDom();

    // The href is root-relative in the markup; what lands on the clipboard has to be shareable.
    expect(writeText).toHaveBeenCalledWith(
      'http://localhost:3000/2026/01/01/hello'
    );
    expect(lastToast()).toEqual({
      message: 'The link has been copied to your clipboard.',
      variant: 'success',
    });
    expect(analytics.trackEvent).toHaveBeenCalledWith('Copy to Clipboard', {
      url: 'http://localhost:3000/2026/01/01/hello',
    });
  });

  it('suppresses the link navigation so the copy can run', async () => {
    await mountClipboard(vi.fn().mockResolvedValue(undefined));
    const event = new MouseEvent('click', { bubbles: true, cancelable: true });

    document.querySelector('a').dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
  });

  it('swaps the link icon for a checkmark, then swaps back after two seconds', async () => {
    vi.useFakeTimers();
    const { element } = await mountClipboard(
      vi.fn().mockResolvedValue(undefined)
    );

    element.click();
    await flushDom();

    expect(linkIcon().classList.contains('hidden')).toBe(true);
    expect(checkIcon().classList.contains('hidden')).toBe(false);

    vi.advanceTimersByTime(2000);

    expect(linkIcon().classList.contains('hidden')).toBe(false);
    expect(checkIcon().classList.contains('hidden')).toBe(true);
  });

  it('cancels the pending revert when the element goes away', async () => {
    // Turbo navigating away mid-countdown would otherwise leave a timer poking at a detached
    // node, and — worse — one that fires against the next page's icons if they are reused.
    vi.useFakeTimers();
    const { element } = await mountClipboard(
      vi.fn().mockResolvedValue(undefined)
    );
    element.click();
    await flushDom();
    const link = linkIcon();

    element.remove();
    await flushDom();
    vi.advanceTimersByTime(5000);

    expect(link.classList.contains('hidden')).toBe(true); // never reverted
  });

  it('reports failure when the clipboard write is rejected', async () => {
    // Safari rejects writeText outside a user gesture, and any browser rejects it without
    // permission.
    const { element } = await mountClipboard(
      vi.fn().mockRejectedValue(new Error('denied'))
    );

    element.click();
    await flushDom();

    expect(lastToast()).toEqual({
      message: 'Failed to copy link to clipboard.',
      variant: 'danger',
    });
  });

  it('leaves the icons alone when the copy fails', async () => {
    const { element } = await mountClipboard(
      vi.fn().mockRejectedValue(new Error('denied'))
    );

    element.click();
    await flushDom();

    expect(checkIcon().classList.contains('hidden')).toBe(true);
  });

  it('reports failure when the browser has no Clipboard API at all', async () => {
    const { element } = await mountClipboard(null);

    element.click();
    await flushDom();

    expect(lastToast().variant).toBe('danger');
    expect(analytics.trackEvent).not.toHaveBeenCalled();
  });

  it('uses a caller-supplied success message', async () => {
    const { element } = await mountClipboard(
      vi.fn().mockResolvedValue(undefined),
      `<a href="/x" data-controller="clipboard" data-action="clipboard#copy"
          data-clipboard-hidden-class="hidden"
          data-clipboard-success-message-value="Copied!"></a>`
    );

    element.click();
    await flushDom();

    expect(lastToast().message).toBe('Copied!');
  });

  it('still copies and reports when the icon targets are absent', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    const { element } = await mountClipboard(
      writeText,
      `<a href="/x" data-controller="clipboard" data-action="clipboard#copy"
          data-clipboard-hidden-class="hidden"></a>`
    );

    element.click();
    await flushDom();

    expect(writeText).toHaveBeenCalled();
    expect(lastToast().variant).toBe('success');
  });
});
