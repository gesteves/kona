// First-party proxy for Plausible analytics, adapted from Plausible's official Cloudflare
// Workers guide (https://plausible.io/docs/proxy/guides/cloudflare) as a route handler
// inside this Worker instead of a standalone one.
//
// ⚠️ Do not "clean up" the /pa/ path: paths containing "plausible", "analytics",
// "tracking", or "stats" get blocked by content blockers. The obfuscated prefix is the
// feature.

// These paths must match the Ruby constants in web/lib/helpers/site_helpers.rb
// (PLAUSIBLE_SCRIPT_PATH / PLAUSIBLE_EVENT_PATH / PLAUSIBLE_EVENT_UPSTREAM) — the inline
// init snippet is generated from those, so the browser-facing path and this proxy have to
// agree.
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
    // break a page. The script tag and event POST both fail silently in the browser.
    console.error('Plausible proxy failed:', pathname, error);
    return new Response(null, { status: 502 });
  }
}

// Serve the tracking script from cache, fetching the upstream copy on a miss. Per the
// official guide, the copy is cached in caches.default keyed on our own URL; only ok
// responses are stored so an upstream error is never pinned.
async function getScript(
  request: Request,
  env: Env,
  ctx: ExecutionContext
): Promise<Response> {
  let response = await caches.default.match(request);
  if (!response) {
    response = await fetch(env.PLAUSIBLE_SCRIPT_URL!);
    if (response.ok)
      ctx.waitUntil(caches.default.put(request, response.clone()));
  }
  return response;
}

// Forward the event POST upstream with the visitor's cookies stripped (the guide's one
// hard requirement — Plausible is cookieless and the proxy must keep it that way).
// Method, body, and content-type all pass through: /pa/event is a POST, and proxying
// it as anything else makes analytics silently stop recording while the script tag keeps
// loading fine.
async function postEvent(request: Request): Promise<Response> {
  const upstream = new Request(EVENT_UPSTREAM, request);
  upstream.headers.delete('cookie');
  return fetch(upstream);
}
