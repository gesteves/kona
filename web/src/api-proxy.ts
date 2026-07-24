import { requestLogLine } from './log';

// Proxies /widgets/* and the contact-form POST /api/contact to the kona-api origin (fly.io).
// The cross-app contract these two routes have to honor is in the root CLAUDE.md.

// Request headers forwarded upstream on the CONTACT path only. Everything else (cookies,
// conditional headers, the client's own authorization, etc.) is dropped.
//
// ⚠️ `accept` is deliberately NOT forwarded on the widget paths. The widget fetch is edge-cached
// under a URL-only key, so forwarding a header that differs per browser (Chrome and Safari send
// different Accept strings) buys nothing and quietly breaks the "every viewer's upstream request
// is identical" invariant this proxy depends on — if a widget endpoint ever varied its response by
// Accept, the first variant would be pinned for the whole audience. The widget views render
// explicit templates, so sending no Accept leaves Rails on its :html default.
// The contact endpoint is the one route that genuinely needs it: it answers JSON (204/422) to the
// `fetch` path and an HTML 303 to the no-JS native POST, chosen off this header.
const FORWARD_REQUEST_HEADERS = ['accept'];

// The contact-form endpoint. It's a POST (never edge-cached) that needs two things the widget
// paths don't: the real visitor IP/UA/geo forwarded for its Akismet check, rate limit, and the
// notification email (the fly origin can't see them — behind the zone, its own CF-* headers
// describe the Worker egress, not the visitor), and its no-JS redirect's Location header
// forwarded back to the browser.
const CONTACT_PATH = '/api/contact';

// How long to wait on the origin before collapsing the widget. A hung fly machine would otherwise
// hold the request to the platform limit, leaving the placeholder stuck in its loading state;
// aborting drops into the catch below, which returns the empty 502 the live-update controller
// treats as "no data".
//
// ⚠️ Deliberately generous, not aggressive. The origin is a single fly machine that can be
// cold-starting from zero, and the edge's stale-while-revalidate / stale-if-error (see
// api/app/controllers/concerns/live_widget.rb) only rescue a cold start when a cached copy already
// exists — so a tight timeout would collapse widgets on first paint after a scale-to-zero, which
// is exactly when they should be waiting. Not applied to the contact POST.
const WIDGET_UPSTREAM_TIMEOUT_MS = 15_000;

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
  // contactGeo is defined only for the contact path, which is also the only path that forwards
  // any of the client's own request headers (see FORWARD_REQUEST_HEADERS).
  if (contactGeo) {
    for (const name of FORWARD_REQUEST_HEADERS) {
      const value = incoming.get(name);
      if (value) headers.set(name, value);
    }
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
  // + the email's Sender details, never for banning.
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

// The two security headers that matter for a fragment served from this proxy: these responses are
// built from scratch here, so they don't inherit the asset layer's headers (web/source/headers,
// which only covers static assets). The widget fragments are real HTML that renders if navigated
// to directly — so no MIME sniffing, and never framable.
function withFragmentSecurityHeaders(headers: Headers): Headers {
  headers.set('x-content-type-options', 'nosniff');
  headers.set('x-frame-options', 'DENY');
  return headers;
}

// Empty body, briefly cacheable, never durable: the live-update controller collapses the widget on
// any non-2xx (it removes the placeholder), and the empty body matches the origin's render_empty
// for any client that reads the body instead of the status — never "Bad Gateway" text. The short
// cache keeps a momentary origin blip from being hammered.
function badGateway(): Response {
  return new Response('', {
    status: 502,
    headers: withFragmentSecurityHeaders(
      new Headers({ 'cache-control': 'public, max-age=10' })
    ),
  });
}

// Methods each proxied route accepts. Anything else is rejected here, before the origin is touched
// and before the bearer is injected — the origin would only 404 it, and a bodied request would be
// forwarded (and its body read) for nothing.
//
// ⚠️ A GET to /api/contact now 405s rather than falling through to servePage's 404 page. That's
// fine: nothing links to it, and run_worker_first (wrangler.jsonc) means only these paths reach
// Worker code at all.
const ALLOWED_METHODS = ['GET', 'HEAD'];
const ALLOWED_CONTACT_METHODS = ['POST'];

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

  // Coarse geo for the contact path only; IP/UA are read from headers in upstreamHeaders.
  const cf = (request as { cf?: ClientGeo }).cf;
  const contactGeo: ClientGeo | undefined = isContact
    ? { city: cf?.city, region: cf?.region, country: cf?.country }
    : undefined;

  let upstream: Response;
  let upstreamUrl = incoming.pathname;
  try {
    // ⚠️ The query string is STRIPPED, not merely absent: widget inputs are path segments (ids and
    // all), so a query never carries meaning here — but Cloudflare's cache key does include it, so
    // passing one through would let `?anything=random` mint a fresh cache entry and a fresh origin
    // render on every request. /widgets/* is deliberately exempt from the origin's rate limiting
    // (api/config/initializers/rack_attack.rb explains why — all legitimate widget traffic shares
    // this Worker's egress IPs), and these endpoints do real paid/slow work, so that would be a
    // free amplification vector. Dropping the query makes the cache key genuinely path-only.
    //
    // Built inside the try so a missing or malformed KONA_API_URL degrades to the same graceful
    // empty 502 as an origin blip (the widget collapses) instead of throwing an uncaught TypeError
    // and serving Cloudflare's 1101 error page site-wide. A deploy really can strip that var — see
    // the keep_vars note in wrangler.jsonc.
    upstreamUrl = new URL(incoming.pathname, env.KONA_API_URL).toString();

    upstream = await fetch(upstreamUrl, {
      method: request.method,
      headers: upstreamHeaders(request.headers, hasBody, env.API_TOKEN, contactGeo),
      // Streamed, not buffered: never hold a client-supplied body in the isolate. The only bodied
      // request that gets here is the contact POST, whose fields the origin caps anyway
      // (api/app/controllers/api/contact_controller.rb). Tradeoff: a stream can't be replayed, so
      // this subrequest won't be internally retried — a connection blip surfaces as the 502 below
      // and the sender resubmits, which beats buffering an arbitrary body to make retry possible.
      body: hasBody ? request.body : undefined,
      redirect: 'manual',
      // Widget URLs are extensionless, so Cloudflare's extension-based default would cache
      // nothing without this. The TTL itself still comes from the origin: kona-api authors
      // the whole edge policy in CDN-Cache-Control (RFC 9213, honored by Cloudflare), and
      // this fetch cache respects it — no TTL is re-derived here. Responses without that
      // header (errors, no-store paths) follow standard rules and are never durably pinned.
      // Scoped to the cacheable widget GETs — the contact POST is never cached, so it opts out,
      // and only the widget fetch gets the abort timeout (a contact POST should not be cut off).
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
