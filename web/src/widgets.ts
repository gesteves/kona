import { requestLogLine } from './log';

// Proxies /widgets/* to the kona-api origin (fly.io). Port of the Netlify function
// (web/netlify/functions/widget-proxy.mts); the contract is unchanged — see root CLAUDE.md.

// Only these request headers are forwarded upstream. Everything else (cookies, conditional
// headers, the client's own authorization, etc.) is dropped so every viewer's request is
// identical and the whole audience shares a single cache entry.
const FORWARD_REQUEST_HEADERS = ['accept'];

function upstreamHeaders(
  incoming: Headers,
  hasBody: boolean,
  apiToken?: string
): Headers {
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
  // Shared bearer token the kona-api widget endpoints require. Injected here, server-side,
  // so the origin is closed to the public (direct hits without it get a cheap 401) while
  // the token is never exposed to the browser. It's the same for every viewer, so every
  // upstream request stays identical and the audience still shares a single cache entry.
  if (apiToken) headers.set('authorization', `Bearer ${apiToken}`);
  return headers;
}

export async function handleWidgets(
  request: Request,
  env: Env
): Promise<Response> {
  const incoming = new URL(request.url);
  const upstreamUrl = new URL(
    incoming.pathname + incoming.search,
    env.KONA_API_URL
  );
  const hasBody = request.method !== 'GET' && request.method !== 'HEAD';

  let upstream: Response;
  try {
    upstream = await fetch(upstreamUrl.toString(), {
      method: request.method,
      headers: upstreamHeaders(request.headers, hasBody, env.API_TOKEN),
      body: hasBody ? await request.arrayBuffer() : undefined,
      redirect: 'manual',
      // Widget URLs are extensionless, so Cloudflare's extension-based default would cache
      // nothing without this. The TTL itself still comes from the origin: kona-api authors
      // the whole edge policy in CDN-Cache-Control (RFC 9213, honored by Cloudflare), and
      // this fetch cache respects it — no TTL is re-derived here. Responses without that
      // header (errors, no-store paths) follow standard rules and are never durably pinned.
      // The cache key is the bare upstream URL: widget inputs are path segments, no query
      // strings, so entries are already isolated per widget.
      cf: { cacheEverything: true },
    });
  } catch (error) {
    console.error(
      'Widget proxy upstream fetch failed:',
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
    requestLogLine(
      request,
      `${request.method} ${incoming.pathname}`,
      `→ ${upstream.status}`
    )
  );

  const headers = new Headers();
  const contentType = upstream.headers.get('content-type');
  if (contentType) headers.set('content-type', contentType);
  // Pass the origin's Cache-Control through verbatim (this is what the browser sees).
  // CDN-Cache-Control is deliberately NOT forwarded: it's consumed by the fetch cache
  // above, and the browser has no use for the edge policy.
  const cacheControl = upstream.headers.get('cache-control');
  if (cacheControl) headers.set('cache-control', cacheControl);

  return new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers,
  });
}
