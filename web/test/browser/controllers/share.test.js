import { beforeEach, describe, expect, it, vi } from 'vitest';
import ShareController from '../../../source/javascripts/stimulus/controllers/share_controller';
import * as analytics from '../../../source/javascripts/stimulus/lib/analytics';
import { flushDom, mount, stubProperty } from '../helpers';

vi.mock('../../../source/javascripts/stimulus/lib/analytics', () => ({
  trackEvent: vi.fn(),
  trackEventThen: vi.fn(),
}));

const nativeButton = (extraAttrs = '') =>
  `<button class="hidden" data-controller="share" data-share-hidden-class="hidden"
           data-share-is-native-value="true" data-action="share#openShareSheet"
           ${extraAttrs}></button>`;

const shareLink = (href, extraAttrs = '') =>
  `<a href="${href}" data-controller="share" data-share-hidden-class="hidden"
      data-share-via-value="Email" ${extraAttrs}></a>`;

let open;

beforeEach(() => {
  open = vi.fn();
  vi.stubGlobal('open', open);
});

describe('revealing the native share button', () => {
  it('unhides when the browser supports the share sheet', async () => {
    // The button is hidden at the start, and the code shows it only where it works. There is no
    // other method for navigator.share, thus a button that always appears is a button that does
    // nothing in Firefox on a desktop.
    stubProperty(navigator, 'share', vi.fn());

    const { element } = await mount('share', ShareController, nativeButton());

    expect(element.classList.contains('hidden')).toBe(false);
  });

  it('stays hidden without navigator.share', async () => {
    const { element } = await mount('share', ShareController, nativeButton());

    expect(element.classList.contains('hidden')).toBe(true);
  });

  it('stays hidden when the element is not the native trigger', async () => {
    stubProperty(navigator, 'share', vi.fn());

    const { element } = await mount(
      'share',
      ShareController,
      `<button class="hidden" data-controller="share" data-share-hidden-class="hidden"></button>`
    );

    expect(element.classList.contains('hidden')).toBe(true);
  });
});

describe('choosing what to share', () => {
  it('prefers the explicit url and text values', async () => {
    const { controller } = await mount(
      'share',
      ShareController,
      nativeButton(
        'data-share-url-value="https://example.com/a" data-share-text-value="Custom"'
      )
    );

    expect(controller.getShareUrl()).toBe('https://example.com/a');
    expect(controller.getShareText()).toBe('Custom');
  });

  it('falls back to the canonical URL and the og:title', async () => {
    document.head.innerHTML = `
      <link rel="canonical" href="https://example.com/canonical">
      <meta property="og:title" content="OG Title">`;

    const { controller } = await mount(
      'share',
      ShareController,
      nativeButton()
    );

    expect(controller.getShareUrl()).toBe('https://example.com/canonical');
    expect(controller.getShareText()).toBe('OG Title');
  });

  it('falls back again to the location and the document title', async () => {
    document.title = 'Doc Title';

    const { controller } = await mount(
      'share',
      ShareController,
      nativeButton()
    );

    expect(controller.getShareUrl()).toBe(window.location.href);
    expect(controller.getShareText()).toBe('Doc Title');
  });
});

describe('openShareSheet', () => {
  it('opens the native sheet and records the share', async () => {
    const share = vi.fn().mockResolvedValue(undefined);
    stubProperty(navigator, 'share', share);
    document.title = 'Hello';

    const { element } = await mount('share', ShareController, nativeButton());
    element.click();
    await flushDom();

    expect(share).toHaveBeenCalledWith({
      title: 'Hello',
      url: window.location.href,
    });
    expect(analytics.trackEvent).toHaveBeenCalledWith('Share', {
      url: window.location.href,
      via: 'Native',
    });
  });

  it('stays quiet when the visitor dismisses the sheet', async () => {
    // A close of the share sheet is a normal result and not an error. A log line for it would fill
    // the console each time that a person changes their decision.
    const abortError = new Error('share canceled');
    abortError.name = 'AbortError';
    stubProperty(navigator, 'share', vi.fn().mockRejectedValue(abortError));
    const consoleError = vi
      .spyOn(console, 'error')
      .mockImplementation(() => {});

    const { element } = await mount('share', ShareController, nativeButton());
    element.click();
    await flushDom();

    expect(consoleError).not.toHaveBeenCalled();
  });

  it('logs a genuine share failure', async () => {
    stubProperty(
      navigator,
      'share',
      vi.fn().mockRejectedValue(new Error('boom'))
    );
    const consoleError = vi
      .spyOn(console, 'error')
      .mockImplementation(() => {});

    const { element } = await mount('share', ShareController, nativeButton());
    element.click();
    await flushDom();

    expect(consoleError).toHaveBeenCalled();
  });
});

describe('openPopup', () => {
  it('opens a sized popup and records the share', async () => {
    const { element } = await mount(
      'share',
      ShareController,
      shareLink(
        'https://example.com/intent',
        'data-action="share#openPopup" data-share-popup-width-value="600" data-share-popup-height-value="500"'
      )
    );

    element.click();

    expect(open).toHaveBeenCalledWith(
      'https://example.com/intent',
      'share',
      'width=600,height=500,scrollbars=yes,noopener'
    );
    expect(analytics.trackEvent).toHaveBeenCalledWith('Share', {
      url: window.location.href,
      via: 'Email',
    });
  });

  it('falls back to default dimensions', async () => {
    const { element } = await mount(
      'share',
      ShareController,
      shareLink('https://example.com/intent', 'data-action="share#openPopup"')
    );

    element.click();

    expect(open.mock.calls[0][2]).toContain('width=400,height=300');
  });

  it('always passes noopener, so the popup cannot reach back via window.opener', async () => {
    const { element } = await mount(
      'share',
      ShareController,
      shareLink('https://example.com/intent', 'data-action="share#openPopup"')
    );

    element.click();

    expect(open.mock.calls[0][2]).toContain('noopener');
  });
});

describe('trackShare', () => {
  it('waits for the beacon before navigating to a mailto: link', async () => {
    // A navigation in the current window can stop a tracking request in progress. Thus the mailto
    // scheme and the sms scheme go through trackEventThen and navigate from its function. This test
    // does not call that function, on purpose, because jsdom would try to navigate.
    const { element } = await mount(
      'share',
      ShareController,
      shareLink('mailto:someone@example.com', 'data-action="share#trackShare"')
    );

    element.click();

    expect(analytics.trackEventThen).toHaveBeenCalledWith(
      'Share',
      { url: window.location.href, via: 'Email' },
      expect.any(Function)
    );
    expect(open).not.toHaveBeenCalled();
  });

  it('does the same for sms: links', async () => {
    const { element } = await mount(
      'share',
      ShareController,
      shareLink('sms:+15555555555', 'data-action="share#trackShare"')
    );

    element.click();

    expect(analytics.trackEventThen).toHaveBeenCalled();
  });

  it('opens an http(s) link in a new tab, where the beacon is not interrupted', async () => {
    const { element } = await mount(
      'share',
      ShareController,
      shareLink('https://example.com/share', 'data-action="share#trackShare"')
    );

    element.click();

    expect(analytics.trackEvent).toHaveBeenCalled();
    expect(analytics.trackEventThen).not.toHaveBeenCalled();
    expect(open).toHaveBeenCalledWith(
      'https://example.com/share',
      '_blank',
      'noopener,noreferrer'
    );
  });

  it('suppresses the default navigation so the click is not double-counted', async () => {
    const { element } = await mount(
      'share',
      ShareController,
      shareLink('https://example.com/share', 'data-action="share#trackShare"')
    );
    const event = new MouseEvent('click', { bubbles: true, cancelable: true });

    element.dispatchEvent(event);

    expect(event.defaultPrevented).toBe(true);
  });
});
