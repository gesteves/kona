import type { Config } from '@netlify/functions';

// The kona-api origin (fly.io). Reuses the build-time var; must also be exposed to the
// Functions runtime scope on Netlify.
const API_ORIGIN = process.env.KONA_API_URL;

// Only these request headers are forwarded upstream. Everything else (cookies, conditional
// headers, etc.) is dropped so every viewer's request is identical and the whole audience
// shares a single cache entry.
const FORWARD_REQUEST_HEADERS = ['accept', 'authorization'];

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
