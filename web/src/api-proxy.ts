import { requestLogLine } from './log';

// Proxies /widgets/* and the contact-form POST /api/contact to the kona-api origin (fly.io).
// Port of the Netlify function (web/netlify/functions/api-proxy.mts); the contract is
// unchanged — see root CLAUDE.md.

// Only these request headers are forwarded upstream. Everything else (cookies, conditional
// headers, the client's own authorization, etc.) is dropped so every viewer's request is
// identical and the whole audience shares a single cache entry.
const FORWARD_REQUEST_HEADERS = ['accept'];

// The contact-form endpoint. It's a POST (never edge-cached) that needs two things the widget
// paths don't: the real visitor IP/UA/geo forwarded for its Akismet check, rate limit, and the
// notification email (the fly origin can't see them — behind the zone, its own CF-* headers
// describe the Worker egress, not the visitor), and its no-JS redirect's Location header
// forwarded back to the browser.
const CONTACT_PATH = '/api/contact';

// The real visitor's coarse location, read from request.cf (the canonical, always-populated
// Worker API — no managed transform needed, same source as log.ts). Forwarded only for the
// contact path.
type ClientGeo = { city?: string; region?: string; country?: string };

function upstreamHeaders(
  incoming: Headers,
  hasBody: boolean,
  apiToken?: string,
  contactGeo?: ClientGeo
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
  // Give the contact endpoint the real visitor signal it can't otherwise see. IP/UA come from
  // the incoming request (CF-Connecting-IP is always present behind the zone; UA verbatim);
  // geo comes from request.cf (passed in as contactGeo). They ride under custom X-Kona-Client-*
  // names the api reads and Cloudflare won't rewrite. The api trusts them only for spam scoring
  // + the email's Sender details, never for banning. contactGeo is defined only for the contact
  // path, so widget upstream requests stay byte-identical.
  if (contactGeo) {
    const ip = incoming.get('cf-connecting-ip');
    if (ip) headers.set('x-kona-client-ip', ip); // Akismet + rate limit + email
    const ua = incoming.get('user-agent');
    if (ua) headers.set('x-kona-client-ua', ua); // Akismet + email
    if (contactGeo.city) headers.set('x-kona-client-city', contactGeo.city); // email Sender details
    if (contactGeo.region) headers.set('x-kona-client-region', contactGeo.region);
    if (contactGeo.country) headers.set('x-kona-client-country', contactGeo.country);
  }
  // Shared bearer token the kona-api endpoints require (widgets + /api/contact). Injected here,
  // server-side, so the origin is closed to the public (direct hits without it get a cheap 401)
  // while the token is never exposed to the browser. It's the same for every viewer, so every
  // widget upstream request stays identical and the audience still shares a single cache entry.
  if (apiToken) headers.set('authorization', `Bearer ${apiToken}`);
  return headers;
}

export async function handleApi(
  request: Request,
  env: Env
): Promise<Response> {
  const incoming = new URL(request.url);
  const upstreamUrl = new URL(
    incoming.pathname + incoming.search,
    env.KONA_API_URL
  );
  const hasBody = request.method !== 'GET' && request.method !== 'HEAD';
  const isContact = incoming.pathname === CONTACT_PATH;

  // Coarse geo for the contact path only; IP/UA are read from headers in upstreamHeaders.
  const cf = (request as { cf?: ClientGeo }).cf;
  const contactGeo: ClientGeo | undefined = isContact
    ? { city: cf?.city, region: cf?.region, country: cf?.country }
    : undefined;

  let upstream: Response;
  try {
    upstream = await fetch(upstreamUrl.toString(), {
      method: request.method,
      headers: upstreamHeaders(request.headers, hasBody, env.API_TOKEN, contactGeo),
      body: hasBody ? await request.arrayBuffer() : undefined,
      redirect: 'manual',
      // Widget URLs are extensionless, so Cloudflare's extension-based default would cache
      // nothing without this. The TTL itself still comes from the origin: kona-api authors
      // the whole edge policy in CDN-Cache-Control (RFC 9213, honored by Cloudflare), and
      // this fetch cache respects it — no TTL is re-derived here. Responses without that
      // header (errors, no-store paths) follow standard rules and are never durably pinned.
      // The cache key is the bare upstream URL: widget inputs are path segments, no query
      // strings, so entries are already isolated per widget. Scoped to the cacheable widget
      // GETs — the contact POST is never cached, so it opts out.
      ...(isContact ? {} : { cf: { cacheEverything: true } }),
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
