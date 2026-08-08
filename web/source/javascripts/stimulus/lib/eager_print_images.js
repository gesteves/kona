// Every entry image is `loading="lazy"`, and Chrome and Firefox force those to load before they
// paginate. Safari doesn't: it prints whatever has already loaded, so an article printed without
// being scrolled through comes out with its photos missing (only the blurhash placeholder, and
// only if the reader has "print backgrounds" on).

/**
 * Switches every lazy image to eager so the print layout can include it.
 * @returns {void}
 */
export function eagerLoadImages() {
  document.querySelectorAll('img[loading="lazy"]').forEach((img) => {
    img.setAttribute('loading', 'eager');
  });
}

/**
 * Listens for both routes into print. ⚠️ Both are needed: `beforeprint` doesn't fire in every
 * Safari path, and the media query alone misses printing from a background tab.
 * @returns {void}
 */
export function watchForPrint() {
  window.addEventListener('beforeprint', eagerLoadImages);
  matchMedia('print').addEventListener('change', (event) => {
    if (event.matches) {
      eagerLoadImages();
    }
  });
}

watchForPrint();
