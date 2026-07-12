import type { Config, Context } from '@netlify/edge-functions';

// Filters a persistent, high-volume request stream that shares a client signature we
// don't otherwise see from real visitors. Every IP is unique, so it can't be blocked by
// address — the signature is the only handle. We return a 403 rather than the page, so
// the response carries no HTML and no client-side Plausible script: this traffic stays
// out of analytics and off the trending-articles widget.

// True when the user agent matches the signature we're filtering and isn't a client that
// self-identifies as something else.
function isLinuxChrome(userAgent: string): boolean {
  const ua = userAgent.toLowerCase();
  const looksLikeLinuxChrome =
    ua.includes('x11; linux x86_64') &&
    ua.includes('chrome/') &&
    ua.includes('safari/537.36');
  const looksLikeSomethingElse =
    ua.includes('edg/') ||
    ua.includes('opr/') ||
    ua.includes('brave') ||
    ua.includes('firefox') ||
    ua.includes('headlesschrome') ||
    ua.includes('bot') ||
    ua.includes('spider') ||
    ua.includes('crawl');
  return looksLikeLinuxChrome && !looksLikeSomethingElse;
}

// True when the referrer host matches the signature. Host-based, so query strings and
// paths don't matter; a missing or malformed referrer is not a match.
function isGoogleReferrer(referer: string): boolean {
  if (!referer) return false;
  try {
    const host = new URL(referer).hostname.toLowerCase();
    return host === 'www.google.com' || host === 'google.com';
  } catch {
    return false;
  }
}

// The zone is proxied through Cloudflare, so the client that connects to Netlify is a
// Cloudflare edge node: context.ip / context.geo describe the PoP, not the visitor.
// Cloudflare passes the real ones through in CF-* request headers. Fall back to Netlify's
// own values when a request didn't come through Cloudflare — which is exactly the traffic
// this function still exists to catch, so the fallback is load-bearing, not just for dev.
function clientIp(request: Request, context: Context): string | undefined {
  return request.headers.get('CF-Connecting-IP') ?? context.ip;
}

// CF-IPCountry is a 2-letter code present on every proxied request; CF-IPCity only exists
// when the "Add visitor location headers" managed transform is enabled on the zone — hence
// the country-only fallback rather than assuming a city.
function clientGeo(request: Request, context: Context): string | undefined {
  if (request.headers.get('CF-Connecting-IP')) {
    const city = request.headers.get('CF-IPCity');
    const country = request.headers.get('CF-IPCountry');
    return [city, country].filter(Boolean).join(', ') || undefined;
  }
  return context.geo?.city && context.geo?.country?.name
    ? `${context.geo.city}, ${context.geo.country.name}`
    : context.geo?.city || context.geo?.country?.name;
}

// One pipe-separated request log line: the given lead-in parts, then the requester's
// referrer, user agent, IP, and geo (when known). Mirrors the format of the
// known-agents edge function (web/netlify/edge-functions/known-agents.ts) so blocked
// requests read the same way as the rest of the edge logs.
function requestLogLine(
  request: Request,
  context: Context,
  ...parts: (string | null | undefined)[]
): string {
  return [
    ...parts,
    request.headers.get('Referer'),
    request.headers.get('User-Agent'),
    clientIp(request, context),
    clientGeo(request, context),
  ]
    .filter(Boolean)
    .join(' | ');
}

export default async function handler(
  request: Request,
  context: Context
): Promise<Response> {
  const userAgent = request.headers.get('User-Agent') ?? '';
  const referer = request.headers.get('Referer') ?? '';

  if (isLinuxChrome(userAgent) && isGoogleReferrer(referer)) {
    const url = new URL(request.url);
    console.info(
      requestLogLine(
        request,
        context,
        `Blocked ${request.method} ${url.pathname}`,
        '→ 403'
      )
    );
    // no-store so the denial is never cached at the edge and can't leak onto a shared
    // cache entry for this URL that legitimate visitors would then be served.
    return new Response('403 Forbidden\n', {
      status: 403,
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'no-store',
      },
    });
  }

  // Not the bot: pass straight through to the page, unchanged.
  return context.next();
}

export const config: Config = {
  // If this function ever crashes, never block the page: bypass the error so the
  // request chain continues and the downstream page/asset is returned unchanged.
  onError: 'bypass',
  path: '/*',
};
