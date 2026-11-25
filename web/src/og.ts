// The on-demand Open Graph card route, for a page with no cover image: <page path>og.png?v=<v>.
// The path of the card identifies the page: /2026/06/26/post/ gets /2026/06/26/post/og.png, and
// the home page gets /og.png. The page names its own `v` in its og:image, and this code renders
// that version only. Thus each page has one card in the cache, and a card never needs a purge.
// Refer to web/CLAUDE.md.

import { withSecurityHeaders } from './headers';

/** The renderer from the route. Thus a test can use the handler and not import ./og-render. */
export type RenderCard = (title: string) => Promise<Uint8Array<ArrayBuffer>>;

/** This is lazy, thus a widget, contact, or analytics request never runs the satori module code. */
const lazyRender: RenderCard = async (title) =>
  (await import('./og-render')).renderCard(title);

// Keep the ".png": the run_worker_first globs use it, and wrangler.jsonc gives the reason.
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
 * Decodes one numeric character reference. If it cannot, it returns `match`, the full entity
 * text, with no change.
 *
 * ⚠️ A code point outside the range makes `String.fromCodePoint` raise, and this runs on the path
 * of the OG route that catches nothing. One bad entity in an `og:title` would 500 the card.
 * @param raw The digits of the entity.
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
 * This uses HTMLRewriter on a stream, and it does not buffer the page. An article page is large,
 * this route is near the Worker CPU limit, and the tags are in `<head>`. Thus the read stops when
 * it has both tags, or at the end of `<head>`.
 * @returns The title and the image URL, each one decoded.
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
 * ⚠️ This is what limits the route. The caller supplies `v`, and each different value is a cache
 * miss. Without this check, each miss costs a full satori and resvg render and a PNG in the edge
 * cache. A page with a cover image names another image, and it has no card at all.
 * @param image The og:image of the page.
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
 * The only shape that `v` has. `image_helpers.rb` writes `<template>-<published_version>` for an
 * article, `<template>-<CRC32 of the og:title>` for a listing page, and `<template>` with neither.
 */
const VERSION_FORMAT = /^v\d+(-\d+)?$/;

/**
 * Corrects `v` before it becomes part of the cache key.
 *
 * ⚠️ Each value with an unknown shape goes on one key, thus such values cannot make many cache
 * entries. A page that declares such a value still gets its card, on that key. `declaredVersion`
 * limits the values with the known shape.
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
 * @returns A PNG, a 301 to the `v` that the page declares, or a status-line response.
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

  // Make the cache key from the path and `v` only. With an unknown param in the key,
  // `?x=<random>` makes an unlimited number of entries, and each one costs a full render. The key
  // must be a GET, because caches.default serves only GET and put() raises for another method.
  const cacheUrl = new URL(incoming);
  cacheUrl.search = '';
  cacheUrl.hash = '';
  cacheUrl.searchParams.set('v', version);
  const cacheKey = new Request(cacheUrl.toString());

  const cached = await caches.default.match(cacheKey);
  if (cached) {
    // A copy: the body of a Response is one stream, and a second read of the same object raises.
    return request.method === 'HEAD'
      ? new Response(null, cached)
      : new Response(cached.body, cached);
  }

  // The page comes from the static assets of this deployment, thus there is no network request.
  // ⚠️ The code sets `pathname` and does not make a relative URL, for the same reason as
  // api-proxy.ts. Thus a "//evil.example" path stays on this host.
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
