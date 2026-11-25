// The on-demand Open Graph card route, for a page with no cover image: <page path>og.png?v=<v>.
// The path of the card identifies the page: /2026/06/26/post/ gets /2026/06/26/post/og.png, and
// the home page gets /og.png. The page names its own `v` in its og:image, and this code renders
// that version only. Thus each page has one card in the cache, and a card never needs a purge.
// Refer to web/CLAUDE.md.

import { requestLogLine } from './log';
import { readOgMeta } from './og-meta';
import {
  READ_METHODS,
  methodNotAllowed,
  securedResponse,
  withoutBodyForHead,
} from './responses';
import { OG_FILENAME, isOgPath } from './routes';

/** The renderer from the route. Thus a test can use the handler and not import ./og-render. */
type RenderCard = (title: string) => Promise<Uint8Array<ArrayBuffer>>;

/** This is lazy, thus a widget, contact, or analytics request never runs the satori module code. */
const lazyRender: RenderCard = async (title) =>
  (await import('./og-render')).renderCard(title);

/** The (path, v) pair addresses a rendered card, thus a card never changes. */
const IMMUTABLE = 'public, max-age=31536000, immutable';
/** All the other responses, thus a temporary failure never stays in the cache. */
const SHORT = 'public, max-age=300';

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

const STATUS_HEADERS = {
  'content-type': 'text/plain; charset=utf-8',
  'cache-control': SHORT,
};

const statusLine = (status: number): string =>
  `${status} ${STATUS_TEXT[status]}`;

/**
 * Makes a response that is not an image, and its body is only its status line. The callers are
 * crawlers and unfurlers that use the status. The cause of a failure goes in the logs, not in the
 * body.
 */
function statusResponse(status: number): Response {
  return securedResponse(statusLine(status), {
    status,
    headers: STATUS_HEADERS,
  });
}

/**
 * The URL of a card with `v` as its only param.
 *
 * With an unknown param in the URL, `?x=<random>` makes an unlimited number of cache entries, and
 * each one costs a full render.
 */
function cardUrl(incoming: URL, version: string): URL {
  const url = new URL(incoming);
  url.search = '';
  url.hash = '';
  url.searchParams.set('v', version);
  return url;
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
  if (!READ_METHODS.includes(request.method)) {
    return methodNotAllowed(READ_METHODS, statusLine(405), STATUS_HEADERS);
  }

  const incoming = new URL(request.url);
  const version = cacheVersion(incoming.searchParams.get('v'));

  // This is a safety check. The router and the run_worker_first globs use this suffix, thus a
  // request without it means that the two do not agree.
  if (!isOgPath(incoming.pathname)) return statusResponse(400);

  // Remove only the file name and keep the slash at the end. The asset lookup below needs that
  // shape.
  const path = incoming.pathname.slice(0, -OG_FILENAME.length);

  // The cache key is the path and `v` only. The key must be a GET, because caches.default serves
  // only GET and put() raises for another method.
  const cacheKey = new Request(cardUrl(incoming, version).toString());

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
    return securedResponse(null, {
      status: 301,
      headers: {
        location: cardUrl(incoming, declared).toString(),
        'cache-control': SHORT,
      },
    });
  }

  let png: Uint8Array<ArrayBuffer>;
  try {
    png = await render(meta.title);
  } catch (error) {
    // This is the only record of a render failure. The response is only a status line, and a
    // bad template shows only as a social embed with no image.
    console.error(
      requestLogLine(
        request,
        'OG render failed',
        path,
        error instanceof Error ? error.message : String(error)
      )
    );
    return statusResponse(500);
  }

  const response = securedResponse(png, {
    status: 200,
    headers: { 'content-type': 'image/png', 'cache-control': IMMUTABLE },
  });

  ctx.waitUntil(
    caches.default
      .put(cacheKey, response.clone())
      .catch((error) =>
        console.error(
          requestLogLine(
            request,
            'OG card cache put failed',
            path,
            String(error)
          )
        )
      )
  );
  return withoutBodyForHead(request, response);
}
