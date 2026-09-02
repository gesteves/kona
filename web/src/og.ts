// The on-demand Open Graph card route: <page path>og.png?v=<template ver>-<published ver>.
// The path of the card identifies the page, and not a query parameter. Thus /2026/06/26/post/
// gets /2026/06/26/post/og.png, and the home page gets /og.png. The page names its own `v` in
// its og:image, and this code renders that version only: a request with another `v` gets a
// redirect to it. Thus each page has one card in the cache, and a card never needs a purge.
// This renders the og:image for a page with no cover image. Refer to web/CLAUDE.md.

import { withSecurityHeaders } from './headers';

/** The renderer from the route. Thus a test can use the handler and not import ./og-render. */
export type RenderCard = (title: string) => Promise<Uint8Array<ArrayBuffer>>;

/** This is lazy, thus a widget, contact, or analytics request never runs the satori module code. */
const lazyRender: RenderCard = async (title) =>
  (await import('./og-render')).renderCard(title);

// The ".png" is important. Keep it the same as the run_worker_first globs in wrangler.jsonc.
const OG_FILENAME = 'og.png';
export const OG_SUFFIX = `/${OG_FILENAME}`;

/** True for each path of this route: `/og.png` and `/<page path>og.png`. */
export const isOgPath = (pathname: string): boolean =>
  pathname.endsWith(OG_SUFFIX);

/** The (path, v) pair addresses a rendered card, thus a card never changes. */
const IMMUTABLE = 'public, max-age=31536000, immutable';
/** All the other responses, thus a temporary failure never stays in the cache. */
const SHORT = 'public, max-age=300';

const ALLOWED_METHODS = ['GET', 'HEAD'];

/**
 * Decodes the HTML entities that an og:title can contain.
 * `&amp;` comes last: if it came first, `&amp;lt;` would become `<` in a second pass.
 *
 * ⚠️ This is necessary with HTMLRewriter. `Element#getAttribute` gives the attribute **as the
 * source writes it**, with the entities. It does not decode them.
 */
export function decodeEntities(text: string): string {
  return text
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0*39;|&#x0*27;|&apos;/gi, "'")
    .replace(/&#(\d+);/g, (match, d: string) => fromCodePoint(d, 10, match))
    .replace(/&#x([0-9a-f]+);/gi, (match, x: string) =>
      fromCodePoint(x, 16, match)
    )
    .replace(/&amp;/g, '&');
}

/**
 * Decodes one numeric character reference. If it cannot, it gives the entity as the source
 * writes it.
 *
 * ⚠️ A code point outside the range makes `String.fromCodePoint` raise, and this runs on the path
 * of the OG route that catches nothing. One bad entity in an `og:title` would 500 the card.
 *
 * @param raw The digits from the entity.
 * @param radix 10 for a decimal reference, 16 for a hex reference.
 * @param match The full entity text. It returns this with no change if it cannot decode it.
 */
function fromCodePoint(raw: string, radix: number, match: string): string {
  const n = parseInt(raw, radix);
  if (!Number.isInteger(n) || n < 0 || n > 0x10ffff) return match;
  return String.fromCodePoint(n);
}

/** The og:title and the og:image of a page. Each is null when the page has no such tag. */
export type OgMeta = { title: string | null; image: string | null };

/**
 * Reads the og:title and the og:image of a page from its markup.
 *
 * This uses HTMLRewriter on a stream. It does not buffer the page and match a regex, because an
 * article page is a few hundred KB, this route is already near the Worker CPU limit, and the tags
 * are in `<head>`. Thus the read stops when it has both tags, or at the end of `<head>`, usually
 * in the first chunk.
 * @returns The decoded title and the image URL as the source writes it.
 */
export async function readOgMeta(response: Response): Promise<OgMeta> {
  let title: string | null = null;
  let image: string | null = null;
  let headEnded = false;

  const transformed = new HTMLRewriter()
    .on('meta[property="og:title"]', {
      element(element) {
        title ??= element.getAttribute('content');
      },
    })
    .on('meta[property="og:image"]', {
      element(element) {
        image ??= element.getAttribute('content');
      },
    })
    .on('head', {
      element(element) {
        element.onEndTag(() => {
          headEnded = true;
        });
      },
    })
    .transform(response);

  const reader = transformed.body?.getReader();
  if (!reader) return { title: null, image: null };

  try {
    while (!headEnded && (title === null || image === null)) {
      const { done } = await reader.read();
      if (done) break;
    }
  } finally {
    await reader.cancel();
  }

  return {
    title: title === null ? null : decodeEntities(title),
    image: image === null ? null : decodeEntities(image),
  };
}

/**
 * Reads the og:title of a page from its markup.
 * @returns The decoded title, or null if the page has no og:title.
 */
export async function readOgTitle(response: Response): Promise<string | null> {
  return (await readOgMeta(response)).title;
}

/**
 * The `v` that a page declares for this card, from its og:image.
 *
 * ⚠️ This is what limits the route. A well-formed `v` that the page does not declare would
 * otherwise be a cache miss that costs a full render, and there is no end to those values. A page
 * with a cover image names another image, and it has no card at all.
 * @param image The og:image of the page, as the source writes it.
 * @param cardPathname The path of this card.
 * @returns The value for the cache key, or null when the page does not name this card.
 */
function declaredVersion(
  image: string | null,
  cardPathname: string
): string | null {
  if (!image) return null;
  let url: URL;
  try {
    url = new URL(image);
  } catch {
    return null;
  }
  if (url.pathname !== cardPathname) return null;
  return cacheVersion(url.searchParams.get('v'));
}

/**
 * The only shape that `v` has. `image_helpers.rb` writes `OG_TEMPLATE_VERSION` alone for a
 * listing page, or `<template>-<published_version>` for an article.
 */
const VERSION_FORMAT = /^v\d+(-\d+)?$/;

/**
 * Corrects `v` before it becomes part of the cache key.
 *
 * ⚠️ This is what limits the route. To remove the *unknown* params is not sufficient: the caller
 * supplies `v`, and each different value is a cache miss that costs a full satori and resvg
 * render, which is the slowest path in this Worker, and a 1200×630 PNG in the edge cache. This
 * code puts each value that it does not know on one key. Thus a bad URL, or a URL that a person
 * edited, still renders, but it renders one time.
 *
 * @param raw The `v` search param, or null if it is absent.
 * @returns The value for the cache key.
 */
function cacheVersion(raw: string | null): string {
  return raw !== null && VERSION_FORMAT.test(raw) ? raw : '';
}

const STATUS_TEXT: Record<number, string> = {
  400: 'Bad Request',
  404: 'Not Found',
  405: 'Method Not Allowed',
  500: 'Internal Server Error',
};

/**
 * Makes a response that is not an image, and its body is only its status line. The callers are
 * crawlers and unfurlers that use the status. The cause of a failure goes in the logs, not in the
 * body.
 */
function statusResponse(
  status: number,
  extraHeaders?: Record<string, string>
): Response {
  return new Response(`${status} ${STATUS_TEXT[status]}`, {
    status,
    headers: withSecurityHeaders(
      new Headers({
        'content-type': 'text/plain; charset=utf-8',
        'cache-control': SHORT,
        ...extraHeaders,
      })
    ),
  });
}

/**
 * Renders the OG card for the page of this path, or gives it from the cache.
 * @param render The card renderer. The default is the real one, which loads when it is necessary.
 * @returns A PNG, or a status-line response if the page is absent or the render fails.
 */
export async function handleOg(
  request: Request,
  env: Env,
  ctx: ExecutionContext,
  render: RenderCard = lazyRender
): Promise<Response> {
  if (!ALLOWED_METHODS.includes(request.method)) {
    return statusResponse(405, { allow: ALLOWED_METHODS.join(', ') });
  }

  const incoming = new URL(request.url);
  const version = cacheVersion(incoming.searchParams.get('v'));

  // This is a safety check. The router and the run_worker_first globs use this suffix, thus a
  // request without it means that the two do not agree.
  if (!isOgPath(incoming.pathname)) return statusResponse(400);

  // Remove only the file name and keep the slash at the end. The asset lookup below needs that
  // shape.
  const path = incoming.pathname.slice(0, -OG_FILENAME.length);

  // Make the cache key again from the path and `v` only. `v` is what makes the content address a
  // card. The removal of the unknown params stops `?x=<random>` from an unlimited number of
  // entries, and each entry is a miss that costs a full render. It must be a GET, because
  // caches.default serves only GET and put() raises for another method.
  const cacheUrl = new URL(incoming);
  cacheUrl.search = '';
  cacheUrl.hash = '';
  cacheUrl.searchParams.set('v', version);
  const cacheKey = new Request(cacheUrl.toString());

  const cached = await caches.default.match(cacheKey);
  if (cached) {
    return request.method === 'HEAD' ? new Response(null, cached) : cached;
  }

  // The page comes from the static assets of this deployment, thus there is no network request
  // and nothing outside this deployment is available. The code sets `pathname` and does not make
  // a new URL, thus even a "//evil.example" path stays on this host.
  const target = new URL(incoming);
  target.pathname = path;
  target.search = '';
  target.hash = '';

  const page = await env.ASSETS.fetch(new Request(target.toString()));
  // Compare with 200, and not with page.ok. not_found_handling "404-page" returns the 404 page
  // that the build makes, which has an og:title of its own, and auto-trailing-slash returns a
  // redirect.
  if (page.status !== 200) return statusResponse(404);
  if (!(page.headers.get('content-type') ?? '').includes('text/html')) {
    return statusResponse(404);
  }

  const meta = await readOgMeta(page);
  if (!meta.title) return statusResponse(404);

  // Render the version that the page declares, and no other. A request with another `v`, or with
  // none, goes to the declared one, thus each page has one card in the cache.
  const declared = declaredVersion(meta.image, incoming.pathname);
  if (declared === null) return statusResponse(404);
  if (declared !== version) {
    const canonical = new URL(incoming);
    canonical.search = '';
    canonical.hash = '';
    canonical.searchParams.set('v', declared);
    return new Response(null, {
      status: 301,
      headers: withSecurityHeaders(
        new Headers({ location: canonical.toString(), 'cache-control': SHORT })
      ),
    });
  }

  let png: Uint8Array<ArrayBuffer>;
  try {
    png = await render(meta.title);
  } catch (error) {
    // This is the only record of a render failure. The response is only a status line, and a
    // bad template shows only as a social embed with no image.
    console.error(
      'OG render failed:',
      path,
      error instanceof Error ? error.message : String(error)
    );
    return statusResponse(500);
  }

  const response = new Response(png, {
    status: 200,
    headers: withSecurityHeaders(
      new Headers({
        'content-type': 'image/png',
        'cache-control': IMMUTABLE,
      })
    ),
  });

  ctx.waitUntil(
    caches.default
      .put(cacheKey, response.clone())
      .catch((error) => console.error('OG card cache put failed:', path, error))
  );
  return request.method === 'HEAD' ? new Response(null, response) : response;
}
