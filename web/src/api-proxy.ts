import { requestLogLine } from './log';

// Proxies /widgets/* and POST /api/contact to the kona-api origin.
// See the root CLAUDE.md for the cross-app contract these routes honor.

/**
 * Request headers forwarded upstream on the contact path only. Never forwarded on widget
 * paths: those share one URL-keyed edge cache entry, so every upstream request must be
 * byte-identical.
 */
const FORWARD_REQUEST_HEADERS = ['accept'];

/** The contact-form endpoint: a POST that is never cached and forwards visitor IP/UA/geo. */
const CONTACT_PATH = '/api/contact';

/**
 * How long to wait on the origin before collapsing a widget. Generous on purpose — the
 * origin is a single fly machine that may be cold-starting from zero.
 */
const WIDGET_UPSTREAM_TIMEOUT_MS = 15_000;

/** Coarse visitor location from `request.cf`, forwarded on the contact path only. */
type ClientGeo = { city?: string; region?: string; country?: string };

/**
 * Builds the upstream request headers.
 * @param incoming Headers from the client request.
 * @param hasBody Whether the request body is forwarded.
 * @param apiToken Shared bearer injected server-side; constant so viewers share one cache entry.
 * @param contactGeo Set only on the contact path; also enables client header forwarding.
 */
function upstreamHeaders(
  incoming: Headers,
  hasBody: boolean,
  apiToken?: string,
  contactGeo?: ClientGeo
): Headers {
  const headers = new Headers();
  if (contactGeo) {
    for (const name of FORWARD_REQUEST_HEADERS) {
      const value = incoming.get(name);
      if (value) headers.set(name, value);
    }
  }
  if (hasBody) {
    const contentType = incoming.get('content-type');
    if (contentType) headers.set('content-type', contentType);
  }
  // The origin sits behind Cloudflare and can't see the visitor, so pass the real signal
  // under X-Kona-Client-* names. Used for spam scoring and the notification email only.
  if (contactGeo) {
    const ip = incoming.get('cf-connecting-ip');
    if (ip) headers.set('x-kona-client-ip', ip);
    const ua = incoming.get('user-agent');
    if (ua) headers.set('x-kona-client-ua', ua);
    if (contactGeo.city) headers.set('x-kona-client-city', contactGeo.city);
    if (contactGeo.region) headers.set('x-kona-client-region', contactGeo.region);
    if (contactGeo.country) headers.set('x-kona-client-country', contactGeo.country);
  }
  if (apiToken) headers.set('authorization', `Bearer ${apiToken}`);
  return headers;
}

/**
 * Adds the security headers these responses can't inherit from the static asset layer.
 * Widget fragments are real HTML that renders if navigated to directly.
 */
function withFragmentSecurityHeaders(headers: Headers): Headers {
  headers.set('x-content-type-options', 'nosniff');
  headers.set('x-frame-options', 'DENY');
  return headers;
}

/**
 * Weak ETag comparison (RFC 9110 §8.8.3.2): ignores `W/` prefixes and handles a
 * comma-separated If-None-Match list or `*`.
 */
function etagMatches(ifNoneMatch: string, etag: string): boolean {
  const strip = (value: string) => value.trim().replace(/^W\//, '');
  const target = strip(etag);
  return ifNoneMatch
    .split(',')
    .some((candidate) => candidate.trim() === '*' || strip(candidate) === target);
}

/**
 * Empty-bodied 502 with a short cache. The live-update controller collapses the widget on a
 * non-2xx, and the empty body matches the origin's own "no data" signal.
 */
function badGateway(): Response {
  return new Response('', {
    status: 502,
    headers: withFragmentSecurityHeaders(
      new Headers({ 'cache-control': 'public, max-age=10' })
    ),
  });
}

const ALLOWED_METHODS = ['GET', 'HEAD'];
const ALLOWED_CONTACT_METHODS = ['POST'];

/**
 * Proxies a widget or contact-form request to the kona-api origin.
 * @returns The origin's response, a 304, a 405, or an empty 502 if the origin is unreachable.
 */
export async function handleApi(
  request: Request,
  env: Env
): Promise<Response> {
  const incoming = new URL(request.url);
  const isContact = incoming.pathname === CONTACT_PATH;

  const allowed = isContact ? ALLOWED_CONTACT_METHODS : ALLOWED_METHODS;
  if (!allowed.includes(request.method)) {
    return new Response('', {
      status: 405,
      headers: withFragmentSecurityHeaders(
        new Headers({ allow: allowed.join(', ') })
      ),
    });
  }

  const hasBody = request.method !== 'GET' && request.method !== 'HEAD';

  const cf = (request as { cf?: ClientGeo }).cf;
  const contactGeo: ClientGeo | undefined = isContact
    ? { city: cf?.city, region: cf?.region, country: cf?.country }
    : undefined;

  let upstream: Response;
  let upstreamUrl = incoming.pathname;
  try {
    // The query string is stripped: widget inputs are path segments, but Cloudflare's cache
    // key includes the query, so passing one through would let `?x=random` mint a fresh
    // origin render on every request. Built inside the try so a bad KONA_API_URL degrades to
    // the empty 502 below rather than throwing.
    upstreamUrl = new URL(incoming.pathname, env.KONA_API_URL).toString();

    upstream = await fetch(upstreamUrl, {
      method: request.method,
      headers: upstreamHeaders(request.headers, hasBody, env.API_TOKEN, contactGeo),
      // Streamed, not buffered, so no client-supplied body is held in the isolate. A stream
      // can't be replayed, so this subrequest is never internally retried.
      body: hasBody ? request.body : undefined,
      redirect: 'manual',
      // Widget URLs are extensionless, so Cloudflare's extension-based default caches
      // nothing without cacheEverything. The TTL still comes from the origin's
      // CDN-Cache-Control; nothing is re-derived here.
      ...(isContact
        ? {}
        : {
            cf: { cacheEverything: true },
            signal: AbortSignal.timeout(WIDGET_UPSTREAM_TIMEOUT_MS),
          }),
    });
  } catch (error) {
    console.error(
      requestLogLine(
        request,
        `${request.method} ${incoming.pathname}`,
        `→ upstream failed (${upstreamUrl})`,
        error instanceof Error ? error.message : String(error)
      )
    );
    return badGateway();
  }

  const headers = withFragmentSecurityHeaders(new Headers());
  const contentType = upstream.headers.get('content-type');
  if (contentType) headers.set('content-type', contentType);
  // Cache-Control passes through verbatim; CDN-Cache-Control does not — it's consumed by the
  // fetch cache above and the browser has no use for the edge policy.
  const cacheControl = upstream.headers.get('cache-control');
  if (cacheControl) headers.set('cache-control', cacheControl);

  // Age is load-bearing: the browser policy is `max-age=0, stale-while-revalidate=N`, and
  // RFC 9111 has the browser measure that window from the response's age. Without it every
  // viewer gets a full-length window on top of however long the edge held the copy, which
  // reads as a view counter going backwards. Set before the 304 so revalidation updates it.
  const age = upstream.headers.get('age');
  if (age) headers.set('age', age);
  // Forwarded only so cache behavior is visible from a curl.
  const cacheStatus = upstream.headers.get('cf-cache-status');
  if (cacheStatus) headers.set('cf-cache-status', cacheStatus);

  // Forward the validators so the browser's background revalidation can be conditional. The
  // conditional is answered here, never upstream: forwarding If-None-Match would vary the
  // upstream request per client and shatter the shared edge cache entry.
  const etag = upstream.headers.get('etag');
  if (etag) headers.set('etag', etag);
  const lastModified = upstream.headers.get('last-modified');
  if (lastModified) headers.set('last-modified', lastModified);

  if (!isContact && upstream.status === 200 && etag) {
    const ifNoneMatch = request.headers.get('if-none-match');
    if (ifNoneMatch && etagMatches(ifNoneMatch, etag)) {
      return new Response(null, { status: 304, headers });
    }
  }

  // The no-JS contact path answers with a 303; response headers are rebuilt from scratch
  // here, so Location has to be copied explicitly.
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
