import { beforeEach, describe, expect, it, vi } from 'vitest';
import BackToTopController from '../../../source/javascripts/stimulus/controllers/back_to_top_controller';
import { mount } from '../helpers';

const MARKUP =
  '<a href="#top" data-controller="back-to-top" data-action="back-to-top#go">Top</a>';

let scrollTo;

beforeEach(() => {
  scrollTo = vi.fn();
  document.documentElement.scrollTo = scrollTo;
});

describe('back-to-top controller', () => {
  it('scrolls smoothly to the top and suppresses the link navigation', async () => {
    const { element } = await mount('back-to-top', BackToTopController, MARKUP);
    const event = new MouseEvent('click', { bubbles: true, cancelable: true });

    element.dispatchEvent(event);

    expect(scrollTo).toHaveBeenCalledWith({ top: 0, behavior: 'smooth' });
    // Without preventDefault the browser would also jump to #top, racing the smooth scroll.
    expect(event.defaultPrevented).toBe(true);
  });

  it('jumps instantly when the visitor prefers reduced motion', async () => {
    window.matchMedia = (query) => ({
      matches: query === '(prefers-reduced-motion: reduce)',
      media: query,
      addEventListener: () => {},
      removeEventListener: () => {},
    });

    const { element } = await mount('back-to-top', BackToTopController, MARKUP);
    element.dispatchEvent(
      new MouseEvent('click', { bubbles: true, cancelable: true })
    );

    expect(scrollTo).toHaveBeenCalledWith({ top: 0, behavior: 'instant' });
  });
});
