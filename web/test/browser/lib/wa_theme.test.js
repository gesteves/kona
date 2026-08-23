import { beforeEach, describe, expect, it, vi } from 'vitest';

// The loader for the Web Awesome theme stylesheet. Two behaviors here are necessary, and a change
// can break them with no message:
//
//   1. the code puts the stylesheet BEFORE the first stylesheet of the site. The theme gives the
//      default `--wa-*` values, and _toast.scss and _skeleton.scss replace some of them. Those
//      files win by the source order alone, thus at the end the toast renders with the colors of
//      the theme.
//   2. the element that the code adds has NO data-turbo-track. No rendered page contains it, thus
//      Turbo keeps it through each navigation and never adds a second copy.

const THEME_HREF = '/javascripts/site-abc123.css';

const preloadMarkup = (href = THEME_HREF) =>
  `<link rel="preload" as="style" data-wa-theme href="${href}">`;

const stylesheets = () =>
  [...document.head.querySelectorAll('link[rel="stylesheet"]')].map((link) =>
    link.getAttribute('href')
  );

/** Loads the module again, thus its `added` flag starts as false for each test. */
const loadModule = async () => {
  vi.resetModules();
  return import('../../../source/javascripts/stimulus/lib/wa_theme');
};

beforeEach(() => {
  document.head.innerHTML = '';
});

describe('the Web Awesome theme loader', () => {
  it('adds the stylesheet from the URL of the preload element', async () => {
    document.head.innerHTML = preloadMarkup();

    await loadModule();

    expect(stylesheets()).toContain(THEME_HREF);
  });

  // ⚠️ At the end of the head, the site overrides of the --wa-* tokens lose, and the toast and the
  // skeleton render with the colors of the theme at night.
  it('puts the stylesheet before the first stylesheet of the site', async () => {
    document.head.innerHTML =
      preloadMarkup() + '<link rel="stylesheet" href="/stylesheets/site.css">';

    await loadModule();

    expect(stylesheets()).toEqual([THEME_HREF, '/stylesheets/site.css']);
  });

  // ⚠️ data-turbo-track="reload" would put this element in the signature of the tracked elements of
  // Turbo. The element is not in any rendered head, thus each navigation would then be a full page
  // load.
  it('leaves data-turbo-track off the element that it adds', async () => {
    document.head.innerHTML = preloadMarkup();

    await loadModule();

    const added = document.head.querySelector(`link[href="${THEME_HREF}"]`);
    expect(added.hasAttribute('data-turbo-track')).toBe(false);
  });

  it('adds the stylesheet one time, for a second call', async () => {
    document.head.innerHTML = preloadMarkup();

    const module = await loadModule();
    module.loadWebAwesomeTheme();
    module.loadWebAwesomeTheme();

    expect(stylesheets().filter((href) => href === THEME_HREF)).toHaveLength(1);
  });

  // The build always writes the preload. A page with no preload must not raise: the bundle runs on
  // each page.
  it('does nothing, and does not raise, with no preload element', async () => {
    document.head.innerHTML =
      '<link rel="stylesheet" href="/stylesheets/site.css">';

    await expect(loadModule()).resolves.toBeDefined();
    expect(stylesheets()).toEqual(['/stylesheets/site.css']);
  });
});
