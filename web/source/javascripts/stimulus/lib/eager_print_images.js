// Each entry image has `loading="lazy"`, and Chrome and Firefox load each one before they make the
// pages. Safari does not: it prints the images that already loaded. Thus an article that a reader
// prints with no scroll has no photos. It has the blurhash placeholder only, and only when the
// reader sets "print backgrounds" on.

/**
 * Changes each lazy image to eager, thus the print layout can contain it.
 * @returns {void}
 */
export function eagerLoadImages() {
  document.querySelectorAll('img[loading="lazy"]').forEach((img) => {
    img.setAttribute('loading', 'eager');
  });
}

/**
 * Waits for the two ways into a print. ⚠️ Both are necessary: `beforeprint` does not occur in each
 * Safari path, and the media query alone does not find a print from a tab in the background.
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
