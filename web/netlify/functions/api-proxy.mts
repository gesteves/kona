import type { Config, Context } from '@netlify/functions';
import { requestLogLine } from './lib/log.mts';

// The kona-api origin (fly.io). Reuses the build-time var; must also be exposed to the
// Functions runtime scope on Netlify.
const API_ORIGIN = process.env.KONA_API_URL;

// Shared bearer token the kona-api endpoints require. Injected here, server-side, so the origin
// is closed to the public (direct hits without it get a cheap 401) while the token is never
// exposed to the browser. It's the same for every viewer, so every widget upstream request
// stays identical and the audience still shares a single edge-cache entry.
const API_TOKEN = process.env.API_TOKEN;

// Only these request headers are forwarded upstream. Everything else (cookies, conditional
// headers, the client's own authorization, etc.) is dropped so every viewer's request is
// identical and the whole audience shares a single cache entry.
const FORWARD_REQUEST_HEADERS = ['accept'];

// The contact-form endpoint. It's a POST (never edge-cached) that needs two things the widget
// paths don't: the real visitor IP/UA forwarded for its Akismet check (the origin can't see
// them — the zone rewrites CF-Connecting-IP to the Netlify egress IP), and its no-JS redirect's
// Location header forwarded back to the browser.
const CONTACT_PATH = '/api/contact';

function upstreamHeaders(
  incoming: Headers,
  hasBody: boolean,
  isContact: boolean
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
  // Give the contact endpoint's Akismet check real signal. CF-Connecting-IP is the real visitor
  // at the Netlify edge; both are passed under custom names the api reads (and that Cloudflare
  // in front of the origin won't rewrite). The api trusts them only for spam scoring, never for
  // banning. Scoped to the contact path so widget upstream requests stay byte-identical.
  if (isContact) {
    const clientIp = incoming.get('cf-connecting-ip');
    if (clientIp) headers.set('x-kona-client-ip', clientIp);
    const userAgent = incoming.get('user-agent');
    if (userAgent) headers.set('x-kona-client-ua', userAgent);
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
  const isContact = incoming.pathname === CONTACT_PATH;

  let upstream: Response;
  try {
    upstream = await fetch(upstreamUrl, {
      method: req.method,
      headers: upstreamHeaders(req.headers, hasBody, isContact),
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
    requestLogLine(
      req,
      context,
      `${req.method} ${incoming.pathname}`,
      `→ ${upstream.status}`
    )
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

  // The contact form's no-JS path answers a native POST with a 303 to the site's Thank-You
  // page; forward that Location (the response headers are otherwise rebuilt from scratch here,
  // which would drop it). Scoped to the contact redirect so widget behavior is unchanged.
  if (isContact) {
    const location = upstream.headers.get('location');
    if (location) headers.set('location', location);
  }

  return new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers,
  });
}

export const config: Config = {
  path: ['/widgets/*', CONTACT_PATH],
};
