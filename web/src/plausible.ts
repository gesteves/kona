// The first-party proxy for Plausible analytics. It comes from the official Cloudflare Workers
// guide of Plausible (https://plausible.io/docs/proxy/guides/cloudflare).
//
// Do not change the /pa/ path to a clearer name: a content blocker stops a path that contains
// "plausible", "analytics", "tracking", or "stats". The unclear prefix is the purpose.

import { requestLogLine } from './log';
import {
  READ_METHODS,
  methodNotAllowed,
  securedResponse,
  withoutBodyForHead,
} from './responses';
import {
  PLAUSIBLE_EVENT_PATH as EVENT_PATH,
  PLAUSIBLE_SCRIPT_PATH as SCRIPT_PATH,
} from './routes';

const EVENT_UPSTREAM = 'https://plausible.io/api/event';

/** The analytics must never keep a request open. A stop goes to the fallback with no message. */
const UPSTREAM_TIMEOUT_MS = 10_000;

/** The most bytes of an event body. The script sends a few hundred. */
const MAX_EVENT_BYTES = 8_192;

/**
 * Sends a /pa/* request to the script handler or to the event handler.
 * @returns A 404 if there is no analytics configuration. In all other conditions, the response of
 *   the handler, or a fallback with no message, because the analytics must never stop a page.
 */
export async function handlePlausible(
  request: Request,
  env: Env,
  ctx: ExecutionContext
): Promise<Response> {
  // This is the same as plausible_installed? in the Ruby code.
  const scriptUrl = env.PLAUSIBLE_SCRIPT_URL;
  if (!scriptUrl) return notFound();

  const pathname = new URL(request.url).pathname;
  try {
    if (pathname === SCRIPT_PATH) {
      return await getScript(request, scriptUrl, ctx);
    }
    if (pathname === EVENT_PATH) return await postEvent(request);
    return notFound();
  } catch (error) {
    console.error(
      requestLogLine(request, 'Plausible proxy failed', pathname, String(error))
    );
    return pathname === EVENT_PATH ? emptyEvent() : emptyScript();
  }
}

// ⚠️ Each response from this module goes through securedResponse. This route serves JavaScript
// that runs, from the origin of the site, and that is the place where `nosniff` is the most
// important.

function notFound(): Response {
  return securedResponse(null, { status: 404 });
}

/** A script that does nothing, thus an upstream failure never gives a console error. */
function emptyScript(): Response {
  return securedResponse('', {
    status: 200,
    headers: { 'content-type': 'application/javascript' },
  });
}

/** An empty 202, thus the fetch in window.plausible() resolves for an event that goes away. */
function emptyEvent(): Response {
  return securedResponse(null, { status: 202 });
}

/**
 * Serves the tracking script from caches.default, and gets it from upstream on a miss. It obeys
 * the upstream Cache-Control. It stores only a good response, thus an error never stays in the
 * cache.
 */
async function getScript(
  request: Request,
  scriptUrl: string,
  ctx: ExecutionContext
): Promise<Response> {
  if (!READ_METHODS.includes(request.method)) {
    return methodNotAllowed(READ_METHODS);
  }

  // Use the script path alone as the key, and not the request that comes in. The Cache API uses
  // the full URL as its key, thus `?x=<random>` would make an unlimited number of entries, and
  // each one would get the file from the CDN of Plausible again. No code reads a query parameter.
  // A GET key also lets a HEAD request use the same entry.
  const cacheKey = new Request(new URL(SCRIPT_PATH, request.url).toString());

  let response = await caches.default.match(cacheKey);
  if (!response) {
    const upstream = await fetch(scriptUrl, {
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    if (!upstream.ok) return emptyScript();
    // ⚠️ The code makes the headers again from a list of the permitted names, and it does not copy
    // the upstream headers. Each other header of the CDN of Plausible, for example a Set-Cookie,
    // would go to the browser under this origin AND stay in caches.default for its full TTL. The
    // list also removes set-cookie and vary, and caches.default.put() refuses those two.
    const headers = new Headers();
    headers.set(
      'content-type',
      upstream.headers.get('content-type') ?? 'application/javascript'
    );
    for (const name of ['cache-control', 'etag', 'last-modified']) {
      const value = upstream.headers.get(name);
      if (value) headers.set(name, value);
    }
    response = securedResponse(upstream.body, {
      status: upstream.status,
      headers,
    });
    ctx.waitUntil(
      caches.default
        .put(cacheKey, response.clone())
        .catch((error) =>
          console.error(
            requestLogLine(
              request,
              'Plausible script cache put failed',
              String(error)
            )
          )
        )
    );
  }
  return withoutBodyForHead(request, response);
}

/**
 * Sends the event POST upstream with no cookies, because Plausible uses no cookies, and with the
 * true visitor IP in X-Forwarded-For. Without that IP, Plausible sees the egress PoP of this
 * Worker and puts each event at one location, which breaks its unique-visitor hash.
 */
async function postEvent(request: Request): Promise<Response> {
  if (request.method !== 'POST') return methodNotAllowed(['POST']);
  // An event is a small JSON body. A larger one is not from the script, and the relay would
  // only pay to send it.
  const length = Number(request.headers.get('content-length') ?? 0);
  if (length > MAX_EVENT_BYTES) {
    return securedResponse(null, { status: 413 });
  }
  // ⚠️ The headers go upstream from a list, as the script response comes back from one. The
  // request of a client can carry anything. Only these two names, and the X-Forwarded-For that
  // the code adds below, have a use at Plausible.
  const headers = new Headers();
  for (const name of ['content-type', 'user-agent']) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  const clientIp = request.headers.get('CF-Connecting-IP');
  if (clientIp) headers.set('X-Forwarded-For', clientIp);
  const response = await fetch(EVENT_UPSTREAM, {
    method: 'POST',
    headers,
    body: request.body,
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
  });
  // Give the status only. The upstream response with no change would send the Set-Cookie and the
  // CORS headers of Plausible under this origin, and the removal of the cookies above exists to
  // stop that. window.plausible() reads only the status.
  return securedResponse(null, { status: response.status });
}
