import type { Config } from '@netlify/functions';

// The kona-api origin (fly.io). Reuses the build-time var; must also be exposed to the
// Functions runtime scope on Netlify.
const API_ORIGIN = process.env.KONA_API_URL;

// Cache-Control directives that mean "don't store in a shared/edge cache".
const UNCACHEABLE = /\b(?:no-store|no-cache|private)\b/i;

// How long the edge may keep serving a stale response while it revalidates in the
// background. Deliberately longer than the origin's own stale-while-revalidate so the
// widgets keep rendering (slightly stale) even if fly.io is briefly slow or down. The
// browser still receives the origin's own, shorter Cache-Control verbatim.
const EDGE_STALE_WHILE_REVALIDATE = 86400; // 1 day

// Only these request headers are forwarded upstream. Everything else (cookies, conditional
// headers, etc.) is dropped so every viewer's request is identical and the whole audience
// shares a single cache entry.
const FORWARD_REQUEST_HEADERS = ['accept', 'authorization'];

/**
 * Derives the Netlify edge cache header from the origin's Cache-Control:
 *  - adds `durable` so the response lands in Netlify's global durable cache (persisted
 *    across every edge node and across deploys), not just the local edge;
 *  - widens `stale-while-revalidate` to EDGE_STALE_WHILE_REVALIDATE for resilience.
 *
 * Returns null when the origin opts out of shared caching (no-store/no-cache/private) or
 * sends no Cache-Control, so those responses (e.g. /api/location, upstream errors) are
 * never stored at the edge.
 */
function edgeCacheControl(cacheControl: string | null): string | null {
  if (!cacheControl || UNCACHEABLE.test(cacheControl)) return null;

  const directives = cacheControl
    .split(',')
    .map((d) => d.trim())
    .filter(
      (d) =>
        d &&
        !/^stale-while-revalidate=/i.test(d) &&
        d.toLowerCase() !== 'durable'
    );

  directives.push(
    `stale-while-revalidate=${EDGE_STALE_WHILE_REVALIDATE}`,
    'durable'
  );
  return directives.join(', ');
}

function forwardHeaders(incoming: Headers): Headers {
  const headers = new Headers();
  for (const name of FORWARD_REQUEST_HEADERS) {
    const value = incoming.get(name);
    if (value) headers.set(name, value);
  }
  return headers;
}

export default async function handler(req: Request): Promise<Response> {
  const incoming = new URL(req.url);
  const upstreamUrl = new URL(incoming.pathname + incoming.search, API_ORIGIN);
  const hasBody = req.method !== 'GET' && req.method !== 'HEAD';

  let upstream: Response;
  try {
    upstream = await fetch(upstreamUrl, {
      method: req.method,
      headers: forwardHeaders(req.headers),
      body: hasBody ? await req.arrayBuffer() : undefined,
      redirect: 'manual',
    });
  } catch (error) {
    console.error(
      'API proxy upstream fetch failed:',
      upstreamUrl.toString(),
      error
    );
    // Briefly cacheable so a momentary origin blip isn't hammered, but never durable.
    return new Response('Bad Gateway', {
      status: 502,
      headers: { 'cache-control': 'public, max-age=10' },
    });
  }

  const cacheControl = upstream.headers.get('cache-control');
  const headers = new Headers();

  const contentType = upstream.headers.get('content-type');
  if (contentType) headers.set('content-type', contentType);
  // Pass the origin's Cache-Control through verbatim (this is what the browser sees).
  if (cacheControl) headers.set('cache-control', cacheControl);

  // No Netlify-Vary needed: the widget routes key entirely off the path (IDs are path
  // segments, no query params), so the path-based cache key already isolates entries.
  const edge = edgeCacheControl(cacheControl);
  if (edge) headers.set('Netlify-CDN-Cache-Control', edge);

  return new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers,
  });
}

export const config: Config = {
  path: '/api/*',
};
