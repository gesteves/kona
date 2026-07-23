import type { Context } from '@netlify/edge-functions';

// Shared request-logging + client-identity helpers for the Deno edge functions
// (feed-source.ts). These mirror the *format* of the Node functions'
// requestLogLine (web/netlify/functions/lib/log.mts) but can't import it: that helper is a
// Node functions module and these run in the Deno edge runtime. This module lives in a
// subdirectory so Netlify doesn't register it as its own edge function — only files placed
// directly in edge-functions/ are deployed as functions.

// The zone is proxied through Cloudflare, so the client that connects to Netlify is a
// Cloudflare edge node: context.ip / context.geo describe the PoP, not the visitor.
// Cloudflare passes the real ones through in CF-* request headers. Fall back to Netlify's
// own values when a request didn't come through Cloudflare (local dev, or a resolver still
// pointing straight at the origin).
export function clientIp(request: Request, context: Context): string | undefined {
  return request.headers.get('CF-Connecting-IP') ?? context.ip;
}

// CF-IPCountry is a 2-letter code present on every proxied request; CF-IPCity and CF-Region
// ship together in the "Add visitor location headers" managed transform, so both are absent
// unless it's enabled on the zone — hence joining whatever is present rather than assuming a
// city or region. CF-Region is the spelled-out name ("Colorado"), not the CF-RegionCode
// short form. Netlify's own equivalent of the region is geo.subdivision.
export function clientGeo(request: Request, context: Context): string | undefined {
  if (request.headers.get('CF-Connecting-IP')) {
    return (
      [
        request.headers.get('CF-IPCity'),
        request.headers.get('CF-Region'),
        request.headers.get('CF-IPCountry'),
      ]
        .filter(Boolean)
        .join(', ') || undefined
    );
  }
  return (
    [
      context.geo?.city,
      context.geo?.subdivision?.name,
      context.geo?.country?.name,
    ]
      .filter(Boolean)
      .join(', ') || undefined
  );
}

// CF-Ray is set only on requests that actually traversed Cloudflare, so its presence is the
// marker for "this came through the proxy" — a line with no ray bypassed the zone (and so
// bypassed the WAF). It's also the join key against the rayName field in Cloudflare's logs.
export function cloudflareRay(request: Request): string | undefined {
  return request.headers.get('CF-Ray') ?? undefined;
}

// One pipe-separated request log line: the given lead-in parts, then the requester's
// referrer, user agent, IP, geo, and Cloudflare ray (when known). Mirrors the format of the
// widget proxy / OG functions' requestLogLine (web/netlify/functions/lib/log.mts).
export function requestLogLine(
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
    cloudflareRay(request),
  ]
    .filter(Boolean)
    .join(' | ');
}
