import { beforeEach, describe, expect, it, vi } from 'vitest';
import SearchController from '../../../source/javascripts/stimulus/controllers/search_controller';
import * as analytics from '../../../source/javascripts/stimulus/lib/analytics';
import * as pagefind from '../../../source/javascripts/stimulus/lib/pagefind';
import { mount } from '../helpers';

vi.mock('../../../source/javascripts/stimulus/lib/pagefind', () => ({
  loadPagefind: vi.fn().mockResolvedValue(true),
  preloadPagefindWhenIdle: vi.fn(),
}));
vi.mock('../../../source/javascripts/stimulus/lib/analytics', () => ({
  initSearchTracking: vi.fn(),
}));

const MARKUP = `
  <a href="/search" data-controller="search"
     data-action="search#open mouseenter->search#preload focus->search#preload">Search</a>
`;

const mountSearch = () => mount('search', SearchController, MARKUP);

let modal;

beforeEach(() => {
  modal = document.createElement('pagefind-modal');
  modal.open = vi.fn();
});

describe('search controller', () => {
  it('starts the idle preload as soon as a trigger connects', async () => {
    // The first of three layers: the component UI is in the page before a person clicks.
    await mountSearch();

    expect(pagefind.preloadPagefindWhenIdle).toHaveBeenCalled();
  });

  it('prefetches on hover, the earliest signal of intent', async () => {
    const { element } = await mountSearch();

    element.dispatchEvent(new MouseEvent('mouseenter'));

    expect(pagefind.loadPagefind).toHaveBeenCalled();
  });

  it('prefetches on focus, for keyboard users', async () => {
    const { element } = await mountSearch();

    element.dispatchEvent(new FocusEvent('focus'));

    expect(pagefind.loadPagefind).toHaveBeenCalled();
  });

  it('awaits the load, then opens the modal and starts search tracking', async () => {
    const { controller } = await mountSearch();
    document.body.appendChild(modal); // after mount: mount() writes document.body itself

    await controller.open(new MouseEvent('click', { cancelable: true }));

    expect(pagefind.loadPagefind).toHaveBeenCalled();
    expect(modal.open).toHaveBeenCalled();
    expect(analytics.initSearchTracking).toHaveBeenCalled();
  });

  it('suppresses the link navigation', async () => {
    const { controller } = await mountSearch();
    const event = new MouseEvent('click', { cancelable: true });

    await controller.open(event);

    expect(event.defaultPrevented).toBe(true);
  });

  it('tells the nav to close, so dismissing search returns to the page', async () => {
    // On a mobile screen, the Search item is in the open menu.
    document.body.appendChild(modal);
    const onClose = vi.fn();
    document.addEventListener('search:close', onClose);
    const { controller } = await mountSearch();

    await controller.open(new MouseEvent('click', { cancelable: true }));

    expect(onClose).toHaveBeenCalled();
    document.removeEventListener('search:close', onClose);
  });

  it('does not throw when the modal element is not on the page', async () => {
    // In development, /pagefind/ does not exist. Thus the browser never upgrades <pagefind-modal>,
    // and the search does nothing, on purpose, and it gives no error.
    const { controller } = await mountSearch();

    await expect(
      controller.open(new MouseEvent('click', { cancelable: true }))
    ).resolves.toBeUndefined();
  });

  it('does not throw when the modal element exists but has not upgraded', async () => {
    const { controller } = await mountSearch();
    document.body.appendChild(document.createElement('pagefind-modal'));

    await expect(
      controller.open(new MouseEvent('click', { cancelable: true }))
    ).resolves.toBeUndefined();
  });
});
