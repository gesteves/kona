// On-demand Open Graph card route: <page path>og.png?v=<template ver>-<published ver>.
// The page is identified by the card's own path, not by a query parameter — /2026/06/26/post/
// gets /2026/06/26/post/og.png, and the home page gets /og.png. `v` is a pure cache buster and
// is deliberately ignored here, so a card never needs purging.
// Renders the og:image for pages with no cover image; see web/CLAUDE.md.

import { withSecurityHeaders } from './headers';

/** Renderer injected by the route so tests can drive the handler without importing ./og-render. */
export type RenderCard = (title: string) => Promise<Uint8Array<ArrayBuffer>>;

/** Lazy so widget/contact/analytics requests never evaluate satori's module-scope code. */
const lazyRender: RenderCard = async (title) =>
  (await import('./og-render')).renderCard(title);

// The ".png" is load-bearing; keep in sync with the run_worker_first globs in wrangler.jsonc.
const OG_FILENAME = 'og.png';
export const OG_SUFFIX = `/${OG_FILENAME}`;

/** True for any path this route owns: `/og.png` and `/<page path>og.png`. */
export const isOgPath = (pathname: string): boolean =>
  pathname.endsWith(OG_SUFFIX);

/** Rendered cards are content-addressed on (path, v), so they never change. */
const IMMUTABLE = 'public, max-age=31536000, immutable';
/** Everything else, so a transient failure is never durably pinned. */
const SHORT = 'public, max-age=300';

const ALLOWED_METHODS = ['GET', 'HEAD'];

/**
 * Decodes the HTML entities that can appear in an og:title.
 * `&amp;` is handled last: decoding it first would turn `&amp;lt;` into a second-pass `<`.
 *
 * ⚠️ Still needed alongside HTMLRewriter. `Element#getAttribute` hands back the attribute
 * **as written in the source**, entities and all — it does not decode them.
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
 * Decodes one numeric character reference, falling back to the entity as written.
 *
 * ⚠️ Out-of-range code points make `String.fromCodePoint` throw, and this runs on the OG route's
 * uncaught path — a single bad entity in an `og:title` would 500 the card instead of degrading.
 *
 * @param raw The digits from the entity.
 * @param radix 10 for decimal references, 16 for hex.
 * @param match The full entity text, returned unchanged when it can't be decoded.
 */
function fromCodePoint(raw: string, radix: number, match: string): string {
  const n = parseInt(raw, radix);
  if (!Number.isInteger(n) || n < 0 || n > 0x10ffff) return match;
  return String.fromCodePoint(n);
}

/**
 * Reads a page's own og:title out of its markup.
 *
 * Streamed through HTMLRewriter rather than buffered and matched with a regex: an article page
 * runs to a few hundred KB, this route already sits near the Worker CPU budget, and the tag lives
 * in `<head>` — so the read is cancelled as soon as it's found, usually within the first chunk.
 * @returns The decoded title, or null when the page carries no og:title.
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
 * The only shape `v` is ever generated in — `image_helpers.rb` emits `OG_TEMPLATE_VERSION` alone
 * for a listing page, or `<template>-<published_version>` for an article.
 */
const VERSION_FORMAT = /^v\d+(-\d+)?$/;

/**
 * Normalises `v` before it becomes part of the cache key.
 *
 * ⚠️ This is what bounds the route. Dropping *unknown* params isn't enough on its own: `v` is
 * caller-supplied, and every distinct value is a cache miss costing a full satori + resvg render —
 * the most expensive path in this Worker — plus a 1200×630 PNG stored at the edge. Collapsing
 * anything unrecognised onto one key means a junk or hand-edited URL still renders, but renders
 * once.
 *
 * @param raw The `v` search param, or null when absent.
 * @returns The value to key the cache on.
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
 * Builds a non-image response whose body is just its status line. Callers are crawlers and
 * unfurlers that act on the status; the cause of a failure belongs in the logs, not the body.
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
 * Renders (or serves from cache) the OG card for the page this path belongs to.
 * @param render Card renderer; defaults to the lazily imported real one.
 * @returns A PNG, or a status-line response when the page is missing or the render fails.
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

  // Defensive: the router and the run_worker_first globs key on this suffix, so a request
  // without it means the two have drifted apart.
  if (!isOgPath(incoming.pathname)) return statusResponse(400);

  // Strip only the filename, keeping the trailing slash — that's the form the asset lookup
  // below needs.
  const path = incoming.pathname.slice(0, -OG_FILENAME.length);

  // Rebuild the cache key from the path plus only `v`. Keeping `v` is what makes a card
  // content-addressed; dropping unknown params stops `?x=<random>` from minting unbounded
  // entries, each a miss costing a full render. Must be a GET — caches.default only serves
  // GET and put() throws otherwise.
  const cacheUrl = new URL(incoming);
  cacheUrl.search = '';
  cacheUrl.hash = '';
  cacheUrl.searchParams.set('v', version);
  const cacheKey = new Request(cacheUrl.toString());

  const cached = await caches.default.match(cacheKey);
  if (cached) {
    return request.method === 'HEAD' ? new Response(null, cached) : cached;
  }

  // The page comes from the deployed static assets, so no network request is made and nothing
  // outside this deployment is reachable. Assigning `pathname` rather than resolving a new URL
  // keeps even a "//evil.example" path on this host.
  const target = new URL(incoming);
  target.pathname = path;
  target.search = '';
  target.hash = '';

  const page = await env.ASSETS.fetch(new Request(target.toString()));
  // Compare against 200 rather than page.ok: not_found_handling "404-page" returns the built
  // 404 page, which has an og:title of its own, and auto-trailing-slash returns a redirect.
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
    // The only record of a render failure — the response is a bare status line, and a broken
    // template otherwise surfaces only as social embeds quietly losing their image.
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
