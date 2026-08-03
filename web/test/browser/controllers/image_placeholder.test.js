import { describe, expect, it } from 'vitest';
import ImagePlaceholderController from '../../../source/javascripts/stimulus/controllers/image_placeholder_controller';
import { mount } from '../helpers';

// The `placeholder` class paints the blurhash behind an image while it loads. Removing it is
// driven by `load`/`error` actions, plus a connect-time check for the race the actions can't
// cover: an image that finished before the controller attached never fires either event again,
// and would keep its blurhash forever.

const markup = () =>
  `<img class="placeholder" src="/x.jpg"
        data-controller="image-placeholder"
        data-action="load->image-placeholder#removePlaceholder error->image-placeholder#removePlaceholder">`;

// `complete` is a read-only getter on HTMLImageElement, and it has to be in place BEFORE the
// controller connects — that connect-time read is the behaviour under test.
const mountImage = (complete) =>
  mount('image-placeholder', ImagePlaceholderController, markup(), (document) =>
    Object.defineProperty(document.querySelector('img'), 'complete', {
      value: complete,
      configurable: true,
    })
  );

describe('image-placeholder controller', () => {
  it('clears the placeholder for an image that had already finished before connect', async () => {
    // The cached-image case: Turbo restores a page, the <img> is complete on arrival, and no
    // further load event is coming.
    const { element } = await mountImage(true);

    expect(element.classList.contains('placeholder')).toBe(false);
  });

  it('leaves the placeholder in place while the image is still loading', async () => {
    const { element } = await mountImage(false);

    expect(element.classList.contains('placeholder')).toBe(true);
  });

  it('clears the placeholder when the image loads', async () => {
    const { element } = await mountImage(false);

    element.dispatchEvent(new Event('load'));

    expect(element.classList.contains('placeholder')).toBe(false);
  });

  it('clears the placeholder when the image fails, rather than leaving a blur behind', async () => {
    const { element } = await mountImage(false);

    element.dispatchEvent(new Event('error'));

    expect(element.classList.contains('placeholder')).toBe(false);
  });

  it('leaves other classes alone', async () => {
    const { element } = await mount(
      'image-placeholder',
      ImagePlaceholderController,
      '<img class="placeholder cover" data-controller="image-placeholder">'
    );

    element.dispatchEvent(new Event('load'));

    expect(element.className).toBe('cover');
  });
});
