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
    // Turbo navigations don't reload the document, so `turbo:load` is the only pageview signal
    // after the first render.
    await mount('page', PageController, MARKUP);

    document.dispatchEvent(new CustomEvent('turbo:load'));
    document.dispatchEvent(new CustomEvent('turbo:load'));

    expect(analytics.trackPageView).toHaveBeenCalledTimes(2);
  });

  it('empties the toast stack before Turbo caches the page', async () => {
    // A <wa-toast-item>'s countdown dies when Turbo disconnects the DOM and never restarts, so a
    // toast carried into a cached snapshot comes back as a frozen zombie the next time the stack
    // opens.
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
