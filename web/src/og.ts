// The on-demand Open Graph card route: <page path>og.png?v=<template ver>-<published ver>
// — i.e. the card for /2026/06/26/post/ is /2026/06/26/post/og.png, and the home page's is
// /og.png. The page is named by the card's OWN path, not by a query parameter.
//
// Renders the `og:image` for pages that have no cover image (typically Shorts). Replaces the
// retired kona-og fly service (parked on the `restore-og` branch), which did the same job from
// its own host. Moving it in here bought the title lookup below: the page comes from the ASSETS
// binding instead of an HTTP fetch of our own site, which deletes the origin allowlist, the
// network timeout, and the 502 path that service needed — and makes it structurally impossible
// to render caller-supplied text.
//
// The web side builds these URLs in generate_open_graph_image_url (web/lib/helpers/
// image_helpers.rb). `v` is a pure cache buster and is deliberately ignored here: it combines
// OG_TEMPLATE_VERSION with the entry's Contentful published_version, so a republish or a design
// change mints a NEW URL rather than needing the old one invalidated. Nothing about a card ever
// needs purging.

// Injected by the route so the test suite can drive this handler without importing ./og-render —
// the vitest pool's module loader force-types only `.wasm`, so the font/logo Data modules that
// module imports can't load there at all (see web/CLAUDE.md).
export type RenderCard = (title: string) => Promise<Uint8Array<ArrayBuffer>>;

// Lazy, so a /widgets, /api/contact or /pa request never evaluates satori's ~240 KB of
// module-scope code. esbuild keeps a dynamic import of a bundled local module behind an init
// thunk, so evaluation really does defer to the first card render. (The two wasm modules are
// still compiled at isolate startup — that's inherent to static wasm imports, and is what keeps
// compilation off the per-request CPU budget.)
const lazyRender: RenderCard = async (title) =>
  (await import('./og-render')).renderCard(title);

// Every card path is a page path with this filename appended, so stripping the filename (and
// KEEPING the trailing slash — see the asset lookup below) gives the page back.
// ⚠️ The ".png" is load-bearing, not cosmetic — see the run_worker_first comment in
// wrangler.jsonc. Keep this in sync with those entries (`/og.png` + `/*/og.png`).
const OG_FILENAME = 'og.png';
export const OG_SUFFIX = `/${OG_FILENAME}`;

// True for any path this route owns — `/og.png` itself and `/<page path>og.png`. The router uses
// it, so it and the run_worker_first globs have to agree.
export const isOgPath = (pathname: string): boolean =>
  pathname.endsWith(OG_SUFFIX);

// Content-addressed on (path, v), so a rendered card is immutable at a given URL.
const IMMUTABLE = 'public, max-age=31536000, immutable';
// Everything that isn't a rendered card. Short, so a transient wrong state — a page mid-deploy,
// a render blip — is never durably pinned the way a card is.
const SHORT = 'public, max-age=300';

const ALLOWED_METHODS = ['GET', 'HEAD'];

const OG_TITLE_TAG = /<meta[^>]+property=["']og:title["'][^>]*>/i;
const CONTENT_ATTR = /content=["']([^"']*)["']/i;

// og:title's content is HTML-escaped in the markup (it's emitted through `h`), so decode the
// handful of entities that can appear in a title before it goes into the image. Ported from the
// retired service's og/title.mjs, with one deliberate change — the `&amp;` pass moved last; see
// below.
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
    // ⚠️ Last, not first. `&amp;` is the escape for the ampersand that introduces every other
    // entity, so decoding it early would turn `&amp;lt;` (a literal "&lt;" in the title) into a
    // second-pass `<`. Decoding it after everything else leaves one literal ampersand.
    .replace(/&amp;/g, '&');
}

// Reads a page's own og:title — the single source of truth, set by page_title(meta_title_source)
// on the site. Returns null when the markup carries no og:title.
export function extractOgTitle(html: string): string | null {
  const tag = html.match(OG_TITLE_TAG)?.[0];
  const content = tag?.match(CONTENT_ATTR)?.[1];
  return content ? decodeEntities(content) : null;
}

function withSecurityHeaders(headers: Headers): Headers {
  headers.set('x-content-type-options', 'nosniff');
  return headers;
}

// Reason phrases for the statuses this route can return.
const STATUS_TEXT: Record<number, string> = {
  400: 'Bad Request',
  404: 'Not Found',
  405: 'Method Not Allowed',
  500: 'Internal Server Error',
};

// Every non-image response is just its own status line ("404 Not Found"). Nothing reads the body:
// this route is fetched by crawlers and unfurlers, which act on the status, and a failed card
// surfaces as a missing og:image either way. A bespoke message would only be a way to leak which
// internal step failed to anyone probing the endpoint. Why a request failed belongs in the logs
// (see the console.error on the render path), not in a public response body.
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

  // Defensive: the router and the run_worker_first globs both key on this suffix, so a request
  // without it can only mean the two have drifted apart.
  if (!isOgPath(incoming.pathname)) return statusResponse(400);

  // The page this card is for: the card's own path with the filename chopped off, so
  // /2026/06/26/post/og.png → /2026/06/26/post/ and /og.png → /. ⚠️ Only the FILENAME, so the
  // trailing slash survives — that's the form current_page.url has, and the form the asset
  // lookup below wants. There is no caller-supplied path any more: the old `?path=` parameter
  // needed a leading-single-slash check to stop it naming another origin (the last remnant of
  // the retired service's SITE_URL allowlist), and a path taken from our own URL can't name one.
  const path = incoming.pathname.slice(0, -OG_FILENAME.length);

  // ⚠️ Rebuild the key from ONLY the path and the one param this route reads — don't reuse the
  // inbound request. Two separate jobs:
  //   - `v` MUST stay in the key. It's what makes a card content-addressed; drop it and a
  //     republished page's new URL would keep serving the PNG rendered for its old title.
  //   - unknown params MUST be dropped, or ?x=<random> mints an unbounded number of entries,
  //     each one a miss that costs a full render.
  // The key is a GET request: caches.default only serves GET, and put() throws on anything else.
  const cacheUrl = new URL(incoming);
  cacheUrl.search = '';
  cacheUrl.hash = '';
  cacheUrl.searchParams.set('v', version);
  const cacheKey = new Request(cacheUrl.toString());

  const cached = await caches.default.match(cacheKey);
  if (cached) {
    // A HEAD rides the same entry, with the body dropped.
    return request.method === 'HEAD' ? new Response(null, cached) : cached;
  }

  // The page, straight from the deployed static assets — no network request, and no way to reach
  // anything that isn't in this deployment's build. The path keeps the trailing slash that
  // Middleman's directory_indexes emits, which is what the built asset (/about/index.html) is
  // addressed by: html_handling "auto-trailing-slash" (wrangler.jsonc) would answer the
  // slashless form with a REDIRECT, and the status check below only accepts a 200. The binding
  // always goes to the asset layer, so run_worker_first doesn't apply and this lookup can never
  // recurse back into this handler.
  //
  // ⚠️ Assigning `pathname` rather than resolving `new URL(path, incoming)`: the setter can only
  // ever change the path, so even a "//evil.example" pathname stays a path on this host instead
  // of resolving as a protocol-relative URL to another one.
  const target = new URL(incoming);
  target.pathname = path;
  target.search = '';
  target.hash = '';

  const page = await env.ASSETS.fetch(new Request(target.toString()));
  // ⚠️ Compare against 200 rather than using page.ok: not_found_handling: "404-page" means a miss
  // returns the built 404 page's markup, and that page has an og:title of its own. Anything but a
  // clean 200 must not become a card.
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
    // Nothing else surfaces a render failure: the card is only ever fetched by crawlers and
    // unfurlers, so a broken template would otherwise show up as social embeds quietly losing
    // their image. This log line is the ONLY place the cause is recorded — the response itself is
    // a bare status line (see statusResponse). Not cached — see SHORT.
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
