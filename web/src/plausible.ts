// First-party proxy for Plausible analytics, adapted from Plausible's official Cloudflare
// Workers guide (https://plausible.io/docs/proxy/guides/cloudflare).
//
// Do not "clean up" the /pa/ path: paths containing "plausible", "analytics", "tracking", or
// "stats" get blocked by content blockers. The obfuscated prefix is the feature.

import { withSecurityHeaders } from './headers';

// Must match PLAUSIBLE_SCRIPT_PATH / PLAUSIBLE_EVENT_PATH in web/lib/helpers/site_helpers.rb,
// which generate the inline init snippet.
const SCRIPT_PATH = '/pa/script.js';
const EVENT_PATH = '/pa/event';
const EVENT_UPSTREAM = 'https://plausible.io/api/event';

/** Analytics must never hold a request open; an abort falls through to the silent fallback. */
const UPSTREAM_TIMEOUT_MS = 10_000;

/**
 * Routes a /pa/* request to the script or event handler.
 * @returns A 404 when analytics isn't configured, otherwise the handler's response — or a
 *   silent fallback, since analytics must never break a page.
 */
export async function handlePlausible(
  request: Request,
  env: Env,
  ctx: ExecutionContext
): Promise<Response> {
  // Mirrors plausible_installed? on the Ruby side.
  if (!env.PLAUSIBLE_SCRIPT_URL) return notFound();

  const pathname = new URL(request.url).pathname;
  try {
    if (pathname === SCRIPT_PATH) return await getScript(request, env, ctx);
    if (pathname === EVENT_PATH) return await postEvent(request);
    return notFound();
  } catch (error) {
    console.error('Plausible proxy failed:', pathname, error);
    return pathname === EVENT_PATH ? emptyEvent() : emptyScript();
  }
}

/**
 * ⚠️ Every response this module builds goes through withSecurityHeaders. /pa/* is claimed by
 * `run_worker_first`, so it never touches the static asset layer and never gets `source/headers`'
 * `/*` block — and this route serves executable JavaScript from the site's own origin, which
 * without `nosniff` is the one place that matters most.
 */
function securedResponse(
  body: BodyInit | null,
  init: ResponseInit = {}
): Response {
  const headers = withSecurityHeaders(new Headers(init.headers));
  return new Response(body, { ...init, headers });
}

function notFound(): Response {
  return securedResponse(null, { status: 404 });
}

/** A no-op script, so an upstream outage never surfaces as a failed-resource console error. */
function emptyScript(): Response {
  return securedResponse('', {
    status: 200,
    headers: { 'content-type': 'application/javascript' },
  });
}

/** An empty 202, so a dropped event resolves cleanly in window.plausible()'s fetch. */
function emptyEvent(): Response {
  return securedResponse(null, { status: 202 });
}

/**
 * Serves the tracking script from caches.default, fetching upstream on a miss. Honors the
 * upstream Cache-Control; only ok responses are stored, so an error is never pinned.
 */
async function getScript(
  request: Request,
  env: Env,
  ctx: ExecutionContext
): Promise<Response> {
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return securedResponse(null, {
      status: 405,
      headers: { allow: 'GET, HEAD' },
    });
  }

  // Key on the bare script path, not the inbound request: the Cache API keys on the full URL,
  // so `?x=<random>` would mint unbounded entries that each refetch Plausible's CDN. Nothing
  // reads a query param, so normalizing is lossless. A GET key also lets HEAD share the entry.
  const cacheKey = new Request(new URL(SCRIPT_PATH, request.url).toString());

  let response = await caches.default.match(cacheKey);
  if (!response) {
    const upstream = await fetch(env.PLAUSIBLE_SCRIPT_URL!, {
      signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
    });
    if (!upstream.ok) return emptyScript();
    // ⚠️ Rebuilt from an explicit allowlist, not `new Response(upstream.body, upstream)` minus a
    // couple of names. Everything else Plausible's CDN sets — its own CORS and caching headers,
    // any Set-Cookie — would otherwise be re-served under this origin AND persisted in
    // caches.default for its full TTL. The allowlist also drops set-cookie and vary for free,
    // which caches.default.put() rejects outright.
    const headers = withSecurityHeaders(new Headers());
    headers.set(
      'content-type',
      upstream.headers.get('content-type') ?? 'application/javascript'
    );
    // The upstream's own Cache-Control is honored, as before.
    for (const name of ['cache-control', 'etag', 'last-modified']) {
      const value = upstream.headers.get(name);
      if (value) headers.set(name, value);
    }
    response = new Response(upstream.body, {
      status: upstream.status,
      headers,
    });
    ctx.waitUntil(
      caches.default
        .put(cacheKey, response.clone())
        .catch((error) =>
          console.error('Plausible script cache put failed:', error)
        )
    );
  }
  return request.method === 'HEAD' ? new Response(null, response) : response;
}

/**
 * Forwards the event POST upstream with cookies stripped (Plausible is cookieless) and the
 * real visitor IP as X-Forwarded-For — otherwise Plausible sees this Worker's egress PoP and
 * collapses every event to one location, breaking its unique-visitor hash.
 */
async function postEvent(request: Request): Promise<Response> {
  if (request.method !== 'POST') {
    return securedResponse(null, { status: 405, headers: { allow: 'POST' } });
  }
  const upstream = new Request(EVENT_UPSTREAM, request);
  upstream.headers.delete('cookie');
  const clientIp = request.headers.get('CF-Connecting-IP');
  if (clientIp) upstream.headers.set('X-Forwarded-For', clientIp);
  const response = await fetch(upstream, {
    signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
  });
  // Status only. Returning the upstream response verbatim would replay Plausible's own
  // Set-Cookie and CORS headers under this origin, which is the thing the cookie strip above
  // exists to prevent; window.plausible() reads nothing but the status.
  return securedResponse(null, { status: response.status });
}
