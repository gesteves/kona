import type { Config, Context } from '@netlify/functions';

// The kona-api origin (fly.io). Reuses the build-time var; must also be exposed to the
// Functions runtime scope on Netlify.
const API_ORIGIN = process.env.KONA_API_URL;

// Shared bearer token the kona-api widget endpoints require. Injected here, server-side, so
// the origin is closed to the public (direct hits without it get a cheap 401) while the token
// is never exposed to the browser. It's the same for every viewer, so every upstream request
// stays identical and the audience still shares a single edge-cache entry.
const API_TOKEN = process.env.API_TOKEN;

// Only these request headers are forwarded upstream. Everything else (cookies, conditional
// headers, the client's own authorization, etc.) is dropped so every viewer's request is
// identical and the whole audience shares a single cache entry.
const FORWARD_REQUEST_HEADERS = ['accept'];

function upstreamHeaders(incoming: Headers, hasBody: boolean): Headers {
  const headers = new Headers();
  for (const name of FORWARD_REQUEST_HEADERS) {
    const value = incoming.get(name);
    if (value) headers.set(name, value);
  }
  // A forwarded body needs its content-type or the origin can't parse the params. Bodied
  // requests are non-GET (never edge-cached), so this doesn't affect the shared cache entry.
  if (hasBody) {
    const contentType = incoming.get('content-type');
    if (contentType) headers.set('content-type', contentType);
  }
  if (API_TOKEN) headers.set('authorization', `Bearer ${API_TOKEN}`);
  return headers;
}

export default async function handler(
  req: Request,
  context: Context
): Promise<Response> {
  const incoming = new URL(req.url);
  const upstreamUrl = new URL(incoming.pathname + incoming.search, API_ORIGIN);
  const hasBody = req.method !== 'GET' && req.method !== 'HEAD';

  let upstream: Response;
  try {
    upstream = await fetch(upstreamUrl, {
      method: req.method,
      headers: upstreamHeaders(req.headers, hasBody),
      body: hasBody ? await req.arrayBuffer() : undefined,
      redirect: 'manual',
    });
  } catch (error) {
    console.error(
      'API proxy upstream fetch failed:',
      upstreamUrl.toString(),
      error
    );
    // 502 with an empty body: the live-update controller collapses the widget on any non-2xx
    // (it removes the placeholder), and the empty body matches the origin's render_empty for
    // any client that reads the body instead of the status — never "Bad Gateway" text.
    // Briefly cacheable so a momentary origin blip isn't hammered, but never durable.
    return new Response('', {
      status: 502,
      headers: { 'cache-control': 'public, max-age=10' },
    });
  }

  console.info(
    [
      `${req.method} ${incoming.pathname}`,
      `→ ${upstream.status}`,
      req.headers.get('User-Agent'),
      context.ip,
      context.geo?.city && context.geo?.country?.name
        ? `${context.geo.city}, ${context.geo.country.name}`
        : context.geo?.city || context.geo?.country?.name,
    ]
      .filter(Boolean)
      .join(' | ')
  );

  const cacheControl = upstream.headers.get('cache-control');
  const edge = upstream.headers.get('netlify-cdn-cache-control');
  const headers = new Headers();

  const contentType = upstream.headers.get('content-type');
  if (contentType) headers.set('content-type', contentType);
  // Pass the origin's Cache-Control through verbatim (this is what the browser sees).
  if (cacheControl) headers.set('cache-control', cacheControl);

  // Forward the origin's durable-edge policy verbatim — the kona-api app authors the whole
  // directive (durable, max-age, stale-while-revalidate, stale-if-error). The one guard here:
  // never forward it for a non-2xx, so an error/redirect is never durably pinned at the edge,
  // regardless of what the origin emits. Absent header (no-store paths) → not edge-cached.
  // No Netlify-Vary needed: the widget routes key entirely off the path (IDs are path
  // segments, no query params), so the path-based cache key already isolates entries.
  if (edge && upstream.ok) headers.set('Netlify-CDN-Cache-Control', edge);

  return new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers,
  });
}

export const config: Config = {
  path: '/api/*',
};
