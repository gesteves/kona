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
  </div>
`;

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
});
