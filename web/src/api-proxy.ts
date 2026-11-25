import { requestLogLine } from './log';
import { READ_METHODS, methodNotAllowed, securedResponse } from './responses';
import { CONTACT_PATH } from './routes';

// Proxies /widgets/* and POST /api/contact to the kona-api origin.
// Refer to the root CLAUDE.md for the contract between the two apps that these routes obey.

/** The request headers of the client that go upstream, on the contact path only. */
const FORWARD_REQUEST_HEADERS = ['accept'];

/**
 * The time to wait for the origin before a widget request gets the empty 502. It is long, on
 * purpose, because the origin is one fly machine that can start from zero.
 */
const WIDGET_UPSTREAM_TIMEOUT_MS = 15_000;

/**
 * The same limit for the contact POST. It is longer than the limit for a widget, because a form
 * submission is important and a cold start is acceptable. But there is still a limit: without one,
 * an origin that stops leaves the visitor with a spinner until the platform stops the
 * invocation.
 */
const CONTACT_UPSTREAM_TIMEOUT_MS = 25_000;

/**
 * The most bytes of a contact POST that goes upstream. The form is three short fields and a
 * Turnstile token, and the origin has its own length limits. A larger body is not from the form,
 * and the relay would only pay to send it and wake the origin for it.
 */
const MAX_CONTACT_BYTES = 32 * 1024;

/**
 * The approximate visitor location and network from `request.cf`. It goes upstream on the contact
 * path only.
 */
type ClientGeo = {
  city?: string;
  region?: string;
  country?: string;
  asOrganization?: string;
};

/**
 * Makes the upstream request headers of a widget: the bearer token only.
 *
 * ⚠️ No header of the client goes upstream. The widget paths share one edge cache entry with the
 * URL as its key, thus each upstream request must have the same bytes.
 * @param apiToken The shared bearer token. It is constant, thus all the viewers share one entry.
 */
function widgetHeaders(apiToken?: string): Headers {
  const headers = new Headers();
  if (apiToken) headers.set('authorization', `Bearer ${apiToken}`);
  return headers;
}

/**
 * Makes the upstream request headers of the contact POST: the permitted client headers, the
 * content type of the body, the data of the visitor, and the bearer token.
 */
function contactHeaders(request: Request, apiToken?: string): Headers {
  const incoming = request.headers;
  const headers = widgetHeaders(apiToken);
  for (const name of [...FORWARD_REQUEST_HEADERS, 'content-type']) {
    const value = incoming.get(name);
    if (value) headers.set(name, value);
  }
  // Cloudflare is in front of the origin, thus the origin cannot see the visitor. Send the true
  // data with the X-Kona-Client-* names. It is only for the spam score and the notification email.
  const ip = incoming.get('cf-connecting-ip');
  if (ip) headers.set('x-kona-client-ip', ip);
  // ⚠️ A zone rule sets this header from `cf.edge.client_port`, because `request.cf` has no
  // port. The "Set" of that rule replaces a value from the client.
  const port = incoming.get('x-kona-client-port');
  if (port && /^\d{1,5}$/.test(port)) headers.set('x-kona-client-port', port);
  // The time at the edge. A cold start of the origin can add some seconds to its own clock.
  headers.set('x-kona-client-time', new Date().toISOString());
  const ua = incoming.get('user-agent');
  if (ua) headers.set('x-kona-client-ua', ua);
  const geo = (request as { cf?: ClientGeo }).cf;
  if (geo?.city) headers.set('x-kona-client-city', geo.city);
  if (geo?.region) headers.set('x-kona-client-region', geo.region);
  if (geo?.country) headers.set('x-kona-client-country', geo.country);
  if (geo?.asOrganization)
    headers.set('x-kona-client-network', geo.asOrganization);
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

/** The 502 stays in a cache for a short time only, thus a widget comes back soon. */
const BAD_GATEWAY_CACHE = 'public, max-age=10';

/**
 * A 502 with an empty body and a short cache time. On a non-2xx, the live-update controller
 * removes a placeholder, and it keeps an element that has real content.
 */
function badGateway(): Response {
  return securedResponse('', {
    status: 502,
    headers: { 'cache-control': BAD_GATEWAY_CACHE },
  });
}

/** True when `location`, read against `base`, is on the origin of `base`. */
function sameOrigin(location: string, base: URL): boolean {
  try {
    return new URL(location, base).origin === base.origin;
  } catch {
    return false;
  }
}

const CONTACT_METHODS = ['POST'];

/**
 * Sends a request to the kona-api origin, at the path of the request that came in.
 * @param init The parts that the two routes do differently: the headers, the body, the time
 *   limit, and the cache option.
 * @returns The response of the origin, or null if the code cannot reach the origin. The log then
 *   has the cause.
 */
async function fetchOrigin(
  request: Request,
  env: Env,
  init: {
    headers: Headers;
    timeoutMs: number;
    body?: ReadableStream | null;
    cf?: { cacheEverything: boolean };
  }
): Promise<Response | null> {
  const incoming = new URL(request.url);
  let upstreamUrl = incoming.pathname;
  try {
    // The code removes the query string. The widget inputs are path segments, but the Cloudflare
    // cache key includes the query. Thus a query that goes through would let `?x=random` make a
    // new origin render for each request.
    //
    // ⚠️ The code sets `pathname` on the base URL, and it does not make a relative URL against the
    // base. `new URL('//evil.example/x', base)` gives a different ORIGIN, and this request has the
    // API_TOKEN that the code adds. Today the prefixes of the router prevent that, and this code
    // prevents it for each future router.
    //
    // This is in the try block, thus an empty or bad KONA_API_URL raises here and gives the null
    // below. `?? ''` is only for the optional type.
    const upstreamBase = new URL(env.KONA_API_URL ?? '');
    upstreamBase.pathname = incoming.pathname;
    upstreamBase.search = '';
    upstreamBase.hash = '';
    upstreamUrl = upstreamBase.toString();

    return await fetch(upstreamUrl, {
      method: request.method,
      headers: init.headers,
      body: init.body ?? undefined,
      redirect: 'manual',
      // Both routes need a limit. The contact POST is the one request that a visitor waits for.
      signal: AbortSignal.timeout(init.timeoutMs),
      ...(init.cf ? { cf: init.cf } : {}),
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
    return null;
  }
}

/**
 * Makes the response headers from the headers of the origin. It copies a list of names, and no
 * other header of the origin reaches the browser.
 */
function responseHeaders(upstream: Response): Headers {
  const headers = new Headers();
  // Cache-Control goes through with no change. CDN-Cache-Control does not: the fetch cache reads
  // it, and the browser has no use for the edge policy.
  //
  // Age is important: the browser policy is `max-age=0, stale-while-revalidate=N`, and RFC 9111
  // makes the browser measure that window from the age of the response. Without Age, each viewer
  // gets a full window in addition to the time that the edge held the copy, and a view counter
  // then looks like it goes down.
  //
  // cf-cache-status goes through only to make the cache behavior visible in a curl.
  //
  // The validators let the background revalidation of the browser be conditional.
  for (const name of [
    'content-type',
    'cache-control',
    'age',
    'cf-cache-status',
    'etag',
    'last-modified',
  ]) {
    const value = upstream.headers.get(name);
    if (value) headers.set(name, value);
  }
  return headers;
}

/** Gives the body and the status of the origin to the browser, with the given headers. */
function relay(upstream: Response, headers: Headers): Response {
  return securedResponse(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers,
  });
}

/**
 * Proxies a widget request to the origin, through the edge cache.
 * @returns The response from the origin, a 304, a 405, or an empty 502 if the code cannot reach
 *   the origin.
 */
async function handleWidget(request: Request, env: Env): Promise<Response> {
  if (!READ_METHODS.includes(request.method)) {
    return methodNotAllowed(READ_METHODS, '');
  }

  const upstream = await fetchOrigin(request, env, {
    headers: widgetHeaders(env.API_TOKEN),
    timeoutMs: WIDGET_UPSTREAM_TIMEOUT_MS,
    // A widget URL has no extension, thus the Cloudflare default, which uses the extension,
    // caches nothing without cacheEverything. The TTL still comes from the CDN-Cache-Control of
    // the origin, and this code calculates nothing.
    cf: { cacheEverything: true },
  });
  if (!upstream) return badGateway();

  const headers = responseHeaders(upstream);

  // This code answers the conditional request, and never the origin: an If-None-Match that goes
  // upstream would make the upstream request different for each client and would break the one
  // shared edge cache entry. The 304 has the Age of this response, thus a revalidation updates it.
  const etag = upstream.headers.get('etag');
  const ifNoneMatch = request.headers.get('if-none-match');
  if (
    upstream.status === 200 &&
    etag &&
    ifNoneMatch &&
    etagMatches(ifNoneMatch, etag)
  ) {
    return securedResponse(null, { status: 304, headers });
  }

  return relay(upstream, headers);
}

/**
 * Proxies the POST of the contact form to the origin. No cache holds it. It sends the visitor IP,
 * port, UA, geo, network, and the time of the request.
 * @returns The response from the origin, a 405, a 413, or an empty 502 if the code cannot reach
 *   the origin.
 */
async function handleContact(request: Request, env: Env): Promise<Response> {
  if (!CONTACT_METHODS.includes(request.method)) {
    return methodNotAllowed(CONTACT_METHODS, '');
  }

  // A check of the header, and not a read of the body: the body stays a stream below.
  if (Number(request.headers.get('content-length') ?? 0) > MAX_CONTACT_BYTES) {
    return securedResponse('', { status: 413 });
  }

  const upstream = await fetchOrigin(request, env, {
    headers: contactHeaders(request, env.API_TOKEN),
    timeoutMs: CONTACT_UPSTREAM_TIMEOUT_MS,
    // This is a stream, not a buffer, thus the isolate holds no body from the client. The code
    // cannot send a stream again, thus it never does this subrequest a second time.
    body: request.body,
  });
  if (!upstream) return badGateway();

  const headers = responseHeaders(upstream);

  // The path with no JavaScript answers with a 303, thus the response needs its Location. The
  // origin sends the visitor to a page of the site. A Location on another host is not a page of
  // the site, whatever sent it.
  const location = upstream.headers.get('location');
  if (location && sameOrigin(location, new URL(request.url))) {
    headers.set('location', location);
  }

  return relay(upstream, headers);
}

/**
 * Proxies a widget request or a contact-form request to the kona-api origin.
 * @returns The response of the handler of that route.
 */
export async function handleApi(request: Request, env: Env): Promise<Response> {
  return new URL(request.url).pathname === CONTACT_PATH
    ? handleContact(request, env)
    : handleWidget(request, env);
}
