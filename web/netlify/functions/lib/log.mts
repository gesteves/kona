import type { Context } from '@netlify/functions';

// The zone is proxied through Cloudflare, so the client that connects to Netlify is a
// Cloudflare edge node: context.ip / context.geo describe the PoP, not the visitor.
// Cloudflare passes the real ones through in CF-* request headers. Fall back to Netlify's
// own values when a request didn't come through Cloudflare (local dev, or a resolver still
// pointing straight at the origin) — so this is correct on both paths.
export function clientIp(req: Request, context: Context): string | undefined {
  return req.headers.get('CF-Connecting-IP') ?? context.ip;
}

// CF-IPCountry is a 2-letter code present on every proxied request; CF-IPCity only exists
// when the "Add visitor location headers" managed transform is enabled on the zone — hence
// the country-only fallback rather than assuming a city.
export function clientGeo(req: Request, context: Context): string | undefined {
  if (req.headers.get('CF-Connecting-IP')) {
    const city = req.headers.get('CF-IPCity');
    const country = req.headers.get('CF-IPCountry');
    return [city, country].filter(Boolean).join(', ') || undefined;
  }
  return context.geo?.city && context.geo?.country?.name
    ? `${context.geo.city}, ${context.geo.country.name}`
    : context.geo?.city || context.geo?.country?.name;
}

// One pipe-separated request log line: the given lead-in parts, then the requester's
// user agent, IP, and geo (when known). Shared by the widget proxy and the OG image
// function. (This file isn't a function entry point — Netlify only treats
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
  ]
    .filter(Boolean)
    .join(' | ');
}
