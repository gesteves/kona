import type { Context } from '@netlify/functions';

// The zone is proxied through Cloudflare, so the client that connects to Netlify is a
// Cloudflare edge node: context.ip / context.geo describe the PoP, not the visitor.
// Cloudflare passes the real ones through in CF-* request headers. Fall back to Netlify's
// own values when a request didn't come through Cloudflare (local dev, or a resolver still
// pointing straight at the origin) — so this is correct on both paths.
export function clientIp(req: Request, context: Context): string | undefined {
  return req.headers.get('CF-Connecting-IP') ?? context.ip;
}

// CF-IPCountry is a 2-letter code present on every proxied request; CF-IPCity and CF-Region
// ship together in the "Add visitor location headers" managed transform, so both are absent
// unless it's enabled on the zone — hence joining whatever is present rather than assuming a
// city or region. CF-Region is the spelled-out name ("Colorado"), not the CF-RegionCode
// short form. Netlify's own equivalent of the region is geo.subdivision.
export function clientGeo(req: Request, context: Context): string | undefined {
  if (req.headers.get('CF-Connecting-IP')) {
    return (
      [
        req.headers.get('CF-IPCity'),
        req.headers.get('CF-Region'),
        req.headers.get('CF-IPCountry'),
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
// marker for "this came through the proxy" — the one thing the IP can no longer tell us, now
// that we log the visitor's real IP on both paths. A line with no ray bypassed the zone (and
// so bypassed the WAF). It's also the join key against the rayName field in Cloudflare's logs.
export function cloudflareRay(req: Request): string | undefined {
  return req.headers.get('CF-Ray') ?? undefined;
}

// One pipe-separated request log line: the given lead-in parts, then the requester's
// user agent, IP, geo, and Cloudflare ray (when known). Shared by the widget proxy and the
// OG image function. (This file isn't a function entry point — Netlify only treats
// <dir>/<dir>.mts or <dir>/index.mts as one — so it's import-only.)
export function requestLogLine(
  req: Request,
  context: Context,
  ...parts: (string | null | undefined)[]
): string {
  return [
    ...parts,
    req.headers.get('User-Agent'),
    clientIp(req, context),
    clientGeo(req, context),
    cloudflareRay(req),
  ]
    .filter(Boolean)
    .join(' | ');
}
