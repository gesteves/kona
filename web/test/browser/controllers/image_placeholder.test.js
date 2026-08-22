import { describe, expect, it } from 'vitest';
import ImagePlaceholderController from '../../../source/javascripts/stimulus/controllers/image_placeholder_controller';
import { mount } from '../helpers';

// The `placeholder` class draws the blurhash behind an image while that image loads. The `load` and
// `error` actions remove the class. There is also a check at the connect, for the condition that
// those actions cannot cover: an image that completed before the controller attached never sends
// either event again, and it would keep its blurhash for all time.

const markup = () =>
  `<img class="placeholder" src="/x.jpg"
        data-controller="image-placeholder"
        data-action="load->image-placeholder#removePlaceholder error->image-placeholder#removePlaceholder">`;

// `complete` is a read-only getter on HTMLImageElement, and it must have its value BEFORE the
// controller connects. That read at the connect is the behavior that this test covers.
const mountImage = (complete) =>
  mount('image-placeholder', ImagePlaceholderController, markup(), (document) =>
    Object.defineProperty(document.querySelector('img'), 'complete', {
      value: complete,
      configurable: true,
    })
  );

describe('image-placeholder controller', () => {
  it('clears the placeholder for an image that had already finished before connect', async () => {
    // The condition of an image in the cache: Turbo restores a page, the <img> is complete when it
    // arrives, and no load event comes.
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
