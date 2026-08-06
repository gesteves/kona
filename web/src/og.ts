// On-demand Open Graph card route: <page path>og.png?v=<template ver>-<published ver>.
// The page is identified by the card's own path, not by a query parameter — /2026/06/26/post/
// gets /2026/06/26/post/og.png, and the home page gets /og.png. `v` is a pure cache buster and
// is deliberately ignored here, so a card never needs purging.
// Renders the og:image for pages with no cover image; see web/CLAUDE.md.

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

const OG_TITLE_TAG = /<meta[^>]+property=["']og:title["'][^>]*>/i;
const CONTENT_ATTR = /content=["']([^"']*)["']/i;

/**
 * Decodes the HTML entities that can appear in an og:title.
 * `&amp;` is handled last: decoding it first would turn `&amp;lt;` into a second-pass `<`.
 */
export function decodeEntities(text: string): string {
  return text
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0*39;|&#x0*27;|&apos;/gi, "'")
    .replace(/&#(\d+);/g, (_, d: string) => String.fromCodePoint(Number(d)))
    .replace(/&#x([0-9a-f]+);/gi, (_, x: string) =>
      String.fromCodePoint(parseInt(x, 16))
    )
    .replace(/&amp;/g, '&');
}

/**
 * Reads a page's own og:title from its markup.
 * @returns The decoded title, or null when the page carries no og:title.
 */
export function extractOgTitle(html: string): string | null {
  const tag = html.match(OG_TITLE_TAG)?.[0];
  const content = tag?.match(CONTENT_ATTR)?.[1];
  return content ? decodeEntities(content) : null;
}

function withSecurityHeaders(headers: Headers): Headers {
  headers.set('x-content-type-options', 'nosniff');
  return headers;
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
  const version = incoming.searchParams.get('v') ?? '';

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

  const title = extractOgTitle(await page.text());
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

  ctx.waitUntil(caches.default.put(cacheKey, response.clone()));
  return request.method === 'HEAD' ? new Response(null, response) : response;
}
