import { withSecurityHeaders } from './headers';
import { requestLogLine } from './log';

// Proxies /widgets/* and POST /api/contact to the kona-api origin.
// Refer to the root CLAUDE.md for the contract between the two apps that these routes obey.

/**
 * The request headers that go upstream on the contact path only. They never go on a widget path,
 * because the widget paths share one edge cache entry with the URL as its key. Thus each upstream
 * request must have the same bytes.
 */
const FORWARD_REQUEST_HEADERS = ['accept'];

/** The contact-form endpoint: a POST that no cache holds. It sends the visitor IP, UA, and geo. */
const CONTACT_PATH = '/api/contact';

/**
 * The time to wait for the origin before the code removes a widget. It is long, on purpose,
 * because the origin is one fly machine that can start from zero.
 */
const WIDGET_UPSTREAM_TIMEOUT_MS = 15_000;

/**
 * The same limit for the contact POST. It is longer than the limit for a widget, because a form
 * submission is important and a cold start is acceptable. But there is still a limit: without one,
 * an origin that stops leaves the visitor with a spinner until the platform stops the
 * invocation.
 */
const CONTACT_UPSTREAM_TIMEOUT_MS = 25_000;

/** The approximate visitor location from `request.cf`. It goes on the contact path only. */
type ClientGeo = { city?: string; region?: string; country?: string };

/**
 * Makes the upstream request headers.
 * @param incoming The headers from the client request.
 * @param hasBody True if the request body goes upstream.
 * @param apiToken The shared bearer token that the server adds. It is constant, thus all the
 *   viewers share one cache entry.
 * @param contactGeo Set on the contact path only. It also lets the client headers go upstream.
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
  // Cloudflare is in front of the origin, thus the origin cannot see the visitor. Send the true
  // data with the X-Kona-Client-* names. It is only for the spam score and the notification email.
  if (contactGeo) {
    const ip = incoming.get('cf-connecting-ip');
    if (ip) headers.set('x-kona-client-ip', ip);
    const ua = incoming.get('user-agent');
    if (ua) headers.set('x-kona-client-ua', ua);
    if (contactGeo.city) headers.set('x-kona-client-city', contactGeo.city);
    if (contactGeo.region)
      headers.set('x-kona-client-region', contactGeo.region);
    if (contactGeo.country)
      headers.set('x-kona-client-country', contactGeo.country);
  }
  if (apiToken) headers.set('authorization', `Bearer ${apiToken}`);
  return headers;
}

/**
 * A weak ETag comparison (RFC 9110 §8.8.3.2). It ignores a `W/` prefix, and it accepts an
 * If-None-Match list with a comma between the items, or `*`.
 */
function etagMatches(ifNoneMatch: string, etag: string): boolean {
  const strip = (value: string) => value.trim().replace(/^W\//, '');
  const target = strip(etag);
  return ifNoneMatch
    .split(',')
    .some(
      (candidate) => candidate.trim() === '*' || strip(candidate) === target
    );
}

/**
 * A 502 with an empty body and a short cache time. The live-update controller removes the widget
 * on a non-2xx, and the empty body is the same as the "no data" answer from the origin.
 */
function badGateway(): Response {
  return new Response('', {
    status: 502,
    headers: withSecurityHeaders(
      new Headers({ 'cache-control': 'public, max-age=10' })
    ),
  });
}

const ALLOWED_METHODS = ['GET', 'HEAD'];
const ALLOWED_CONTACT_METHODS = ['POST'];

/**
 * Proxies a widget request or a contact-form request to the kona-api origin.
 * @returns The response from the origin, a 304, a 405, or an empty 502 if the code cannot reach
 *   the origin.
 */
export async function handleApi(request: Request, env: Env): Promise<Response> {
  const incoming = new URL(request.url);
  const isContact = incoming.pathname === CONTACT_PATH;

  const allowed = isContact ? ALLOWED_CONTACT_METHODS : ALLOWED_METHODS;
  if (!allowed.includes(request.method)) {
    return new Response('', {
      status: 405,
      headers: withSecurityHeaders(new Headers({ allow: allowed.join(', ') })),
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
    // The code removes the query string. The widget inputs are path segments, but the Cloudflare
    // cache key includes the query. Thus a query that goes through would let `?x=random` make a
    // new origin render for each request. This is in the try block, thus a bad KONA_API_URL gives
    // the empty 502 below and does not raise.
    //
    // ⚠️ The code sets `pathname` on the base URL. It does not make a relative URL against the
    // base, for the same reason as og.ts. `new URL('//evil.example/x', base)` gives a different
    // ORIGIN, and this request has the API_TOKEN that the code adds. Today the prefixes of the
    // router prevent that, and this code prevents it for each future router.
    // `?? ''` is only for the optional type: an empty base raises here, as a base that the code
    // cannot parse does, and the try block is for that condition.
    const upstreamBase = new URL(env.KONA_API_URL ?? '');
    upstreamBase.pathname = incoming.pathname;
    upstreamBase.search = '';
    upstreamBase.hash = '';
    upstreamUrl = upstreamBase.toString();

    upstream = await fetch(upstreamUrl, {
      method: request.method,
      headers: upstreamHeaders(
        request.headers,
        hasBody,
        env.API_TOKEN,
        contactGeo
      ),
      // This is a stream, not a buffer, thus the isolate holds no body from the client. The code
      // cannot send a stream again, thus it never does this subrequest a second time.
      body: hasBody ? request.body : undefined,
      redirect: 'manual',
      // Both paths have a limit. With the timeout in the widgets-only branch below, the contact
      // POST had no limit, and that is the one request that a visitor waits for.
      signal: AbortSignal.timeout(
        isContact ? CONTACT_UPSTREAM_TIMEOUT_MS : WIDGET_UPSTREAM_TIMEOUT_MS
      ),
      // A widget URL has no extension, thus the Cloudflare default, which uses the extension,
      // caches nothing without cacheEverything. The TTL still comes from the CDN-Cache-Control of
      // the origin, and this code calculates nothing. No cache holds the contact POST, on purpose.
      ...(isContact ? {} : { cf: { cacheEverything: true } }),
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

  const headers = withSecurityHeaders(new Headers());
  const contentType = upstream.headers.get('content-type');
  if (contentType) headers.set('content-type', contentType);
  // Cache-Control goes through with no change. CDN-Cache-Control does not: the fetch cache above
  // reads it, and the browser has no use for the edge policy.
  const cacheControl = upstream.headers.get('cache-control');
  if (cacheControl) headers.set('cache-control', cacheControl);

  // Age is important: the browser policy is `max-age=0, stale-while-revalidate=N`, and RFC 9111
  // makes the browser measure that window from the age of the response. Without Age, each viewer
  // gets a full window in addition to the time that the edge held the copy, and a view counter
  // then looks like it goes down. Set it before the 304, thus a revalidation updates it.
  const age = upstream.headers.get('age');
  if (age) headers.set('age', age);
  // This goes through only to make the cache behavior visible in a curl.
  const cacheStatus = upstream.headers.get('cf-cache-status');
  if (cacheStatus) headers.set('cf-cache-status', cacheStatus);

  // Send the validators, thus the background revalidation of the browser can be conditional.
  // This code answers the conditional request, and never the origin: an If-None-Match that goes
  // upstream would make the upstream request different for each client and would break the one
  // shared edge cache entry.
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

  // The contact path with no JavaScript answers with a 303. This code makes new response
  // headers, thus it must copy Location.
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
