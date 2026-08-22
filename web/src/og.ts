// The on-demand Open Graph card route: <page path>og.png?v=<template ver>-<published ver>.
// The path of the card identifies the page, and not a query parameter. Thus /2026/06/26/post/
// gets /2026/06/26/post/og.png, and the home page gets /og.png. `v` is only a cache buster, and
// this code ignores it, on purpose. Thus a card never needs a purge.
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

/**
 * Reads the og:title of a page from its markup.
 *
 * This uses HTMLRewriter on a stream. It does not buffer the page and match a regex, because an
 * article page is a few hundred KB, this route is already near the Worker CPU limit, and the tag
 * is in `<head>`. Thus the read stops when it finds the tag, usually in the first chunk.
 * @returns The decoded title, or null if the page has no og:title.
 */
export async function readOgTitle(response: Response): Promise<string | null> {
  let title: string | null = null;

  const transformed = new HTMLRewriter()
    .on('meta[property="og:title"]', {
      element(element) {
        title ??= element.getAttribute('content');
      },
    })
    .transform(response);

  const reader = transformed.body?.getReader();
  if (!reader) return null;

  try {
    while (title === null) {
      const { done } = await reader.read();
      if (done) break;
    }
  } finally {
    await reader.cancel();
  }

  return title === null ? null : decodeEntities(title);
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

  const title = await readOgTitle(page);
  if (!title) return statusResponse(404);

  let png: Uint8Array<ArrayBuffer>;
  try {
    png = await render(title);
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
