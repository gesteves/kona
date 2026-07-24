// First-party proxy for Plausible analytics, adapted from Plausible's official Cloudflare
// Workers guide (https://plausible.io/docs/proxy/guides/cloudflare) as a route handler
// inside this Worker instead of a standalone one.
//
// ⚠️ Do not "clean up" the /pa/ path: paths containing "plausible", "analytics",
// "tracking", or "stats" get blocked by content blockers. The obfuscated prefix is the
// feature.

// These paths must match the Ruby constants in web/lib/helpers/site_helpers.rb
// (PLAUSIBLE_SCRIPT_PATH / PLAUSIBLE_EVENT_PATH) — the inline init snippet is generated from
// those, so the browser-facing path and this proxy have to agree.
const SCRIPT_PATH = '/pa/script.js';
const EVENT_PATH = '/pa/event';
const EVENT_UPSTREAM = 'https://plausible.io/api/event';

export async function handlePlausible(
  request: Request,
  env: Env,
  ctx: ExecutionContext
): Promise<Response> {
  // Mirrors plausible_installed? on the Ruby side: no upstream script URL configured means
  // the site was built without analytics, so there's nothing to proxy.
  if (!env.PLAUSIBLE_SCRIPT_URL) return new Response(null, { status: 404 });

  const pathname = new URL(request.url).pathname;
  try {
    if (pathname === SCRIPT_PATH) return await getScript(request, env, ctx);
    if (pathname === EVENT_PATH) return await postEvent(request);
    return new Response(null, { status: 404 });
  } catch (error) {
    // Fail open (the guide's passThroughOnException equivalent): analytics must never
    // break a page. Hand back the same silent fallbacks the handlers use so a proxy
    // exception looks identical to an upstream outage in the browser — no console noise.
    console.error('Plausible proxy failed:', pathname, error);
    return pathname === EVENT_PATH ? emptyEvent() : emptyScript();
  }
}

// A no-op script served with a 200 + JS content-type: the <script src> "loads" fine and
// defines nothing, so an upstream outage never surfaces as a failed-resource console error.
function emptyScript(): Response {
  return new Response('', {
    status: 200,
    headers: { 'content-type': 'application/javascript' },
  });
}

// A 202 with no body: window.plausible()'s fetch resolves cleanly, so a dropped event is
// silent rather than a console error.
function emptyEvent(): Response {
  return new Response(null, { status: 202 });
}

// Serve the tracking script from cache, fetching the upstream copy on a miss. Per the
// official guide, the copy is cached in caches.default keyed on our own URL, honoring the
// upstream Cache-Control rather than a hardcoded TTL; only ok responses are stored so an
// upstream error is never pinned.
async function getScript(
  request: Request,
  env: Env,
  ctx: ExecutionContext
): Promise<Response> {
  // ⚠️ Key on the bare script path, NOT the inbound request. The Cache API keys on the full URL
  // including the query string, so caching the request as-is would let /pa/script.js?x=<random>
  // mint an unbounded number of entries, each one a cache miss that refetches Plausible's CDN.
  // Nothing here reads a query param, so normalizing is lossless.
  const cacheKey = new Request(new URL(SCRIPT_PATH, request.url).toString());
  // caches.default only serves GET, and put() *throws* on a non-GET request — a throw that would
  // land inside the waitUntil below, where handlePlausible's fail-open catch can't see it. So skip
  // the cache entirely for anything else (in practice only a HEAD probe) and just proxy it.
  const cacheable = request.method === 'GET';

  let response = cacheable ? await caches.default.match(cacheKey) : undefined;
  if (!response) {
    const upstream = await fetch(env.PLAUSIBLE_SCRIPT_URL!);
    // On an upstream error, don't cache it and don't pass the failing status to the
    // <script src> (which would log a console error) — hand back a no-op script instead.
    if (!upstream.ok) return emptyScript();
    // Rebuild so we can strip Set-Cookie before caching: Plausible's script is cookieless,
    // and caches.default.put() *throws* on a response carrying Set-Cookie — which would drop
    // us into the catch and silently break analytics. Copying upstream as the init preserves
    // its status and Cache-Control, so the TTL still comes from Plausible.
    response = new Response(upstream.body, upstream);
    response.headers.delete('set-cookie');
    if (cacheable) ctx.waitUntil(caches.default.put(cacheKey, response.clone()));
  }
  return response;
}

// Forward the event POST upstream with the visitor's cookies stripped (the guide's one
// hard requirement — Plausible is cookieless and the proxy must keep it that way).
// Method, body, and content-type all pass through: /pa/event is a POST, and proxying
// it as anything else makes analytics silently stop recording while the script tag keeps
// loading fine.
//
// Also forward the real visitor IP as X-Forwarded-For. plausible.io sits behind its own
// Cloudflare, so without this it sees the connecting party as our Worker's egress PoP —
// collapsing every event to one location and breaking the cookieless IP+UA daily hash that
// dedupes unique visitors. CF-Connecting-IP is the only real client IP (root CLAUDE.md);
// X-Forwarded-For is the header Plausible reads through a proxy.
async function postEvent(request: Request): Promise<Response> {
  const upstream = new Request(EVENT_UPSTREAM, request);
  upstream.headers.delete('cookie');
  const clientIp = request.headers.get('CF-Connecting-IP');
  if (clientIp) upstream.headers.set('X-Forwarded-For', clientIp);
  return fetch(upstream);
}
