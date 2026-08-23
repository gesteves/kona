import { describe, expect, it, vi } from 'vitest';
import PageController from '../../../source/javascripts/stimulus/controllers/page_controller';
import * as analytics from '../../../source/javascripts/stimulus/lib/analytics';
import { mount } from '../helpers';

vi.mock('../../../source/javascripts/stimulus/lib/analytics', () => ({
  trackPageView: vi.fn(),
}));

const MARKUP = `
  <div data-controller="page"
       data-action="turbo:load@document->page#load turbo:before-cache@document->page#clearNotifications">
    <div id="notifications"><wa-toast-item>Saved</wa-toast-item></div>
    <main id="main-content" tabindex="-1">Content</main>
    <div id="route-announcer" role="status" aria-live="polite"></div>
  </div>
`;

/** Waits past the timer that announcePage schedules. */
const flushAnnouncer = () => new Promise((resolve) => setTimeout(resolve, 80));

describe('page controller', () => {
  it('tracks a page view on every turbo:load, not just the first', async () => {
    // A Turbo navigation does not load the document again, thus `turbo:load` is the only page-view
    // event after the first render.
    await mount('page', PageController, MARKUP);

    document.dispatchEvent(new CustomEvent('turbo:load'));
    document.dispatchEvent(new CustomEvent('turbo:load'));

    expect(analytics.trackPageView).toHaveBeenCalledTimes(2);
  });

  it('empties the toast stack before Turbo caches the page', async () => {
    // The countdown of a <wa-toast-item> stops when Turbo disconnects the DOM, and it never starts
    // again. Thus a toast in a snapshot in the cache comes back, and it does not move, the next time
    // that the stack opens.
    await mount('page', PageController, MARKUP);

    document.dispatchEvent(new CustomEvent('turbo:before-cache'));

    expect(document.getElementById('notifications').children).toHaveLength(0);
  });

  it('keeps the container itself, only its contents', async () => {
    await mount('page', PageController, MARKUP);

    document.dispatchEvent(new CustomEvent('turbo:before-cache'));

    expect(document.getElementById('notifications')).not.toBeNull();
  });

  it('does not throw on a page with no toast stack', async () => {
    const { controller } = await mount(
      'page',
      PageController,
      '<div data-controller="page"></div>'
    );

    expect(() => controller.clearNotifications()).not.toThrow();
  });

  describe('the route announcer', () => {
    it('says nothing for the first render, because the browser announces that page', async () => {
      await mount('page', PageController, MARKUP);

      document.dispatchEvent(new CustomEvent('turbo:load'));
      await flushAnnouncer();

      expect(document.getElementById('route-announcer').textContent).toBe('');
    });

    it('announces the title of the page after a navigation', async () => {
      await mount('page', PageController, MARKUP);
      document.dispatchEvent(new CustomEvent('turbo:load'));

      document.title = 'A Post \u00b7 Given to Tri';
      document.dispatchEvent(new CustomEvent('turbo:load'));
      await flushAnnouncer();

      expect(document.getElementById('route-announcer').textContent).toBe(
        'A Post \u00b7 Given to Tri'
      );
    });

    it('empties the region before it writes, thus the same title announces again', async () => {
      const { controller } = await mount('page', PageController, MARKUP);
      const region = document.getElementById('route-announcer');
      region.textContent = 'A Post';

      controller.announcePage();

      expect(region.textContent).toBe('');
    });

    it('moves the focus to the main landmark after a navigation, and not before', async () => {
      await mount('page', PageController, MARKUP);

      document.dispatchEvent(new CustomEvent('turbo:load'));
      expect(document.activeElement).not.toBe(
        document.getElementById('main-content')
      );

      document.dispatchEvent(new CustomEvent('turbo:load'));
      expect(document.activeElement).toBe(
        document.getElementById('main-content')
      );
    });

    it('does not throw on a page with no live region and no main landmark', async () => {
      const { controller } = await mount(
        'page',
        PageController,
        '<div data-controller="page"></div>'
      );

      expect(() => {
        controller.announcePage();
        controller.focusMain();
      }).not.toThrow();
    });
  });
});
