import type { Config, Context } from '@netlify/edge-functions';

// Filters requests that share a distinctive signature: a generic Linux desktop Chrome
// user agent combined with a faked Google search referrer, hitting article pages. A
// burst of this traffic kept arriving before this function existed. We don't know who's
// behind it, how it's driven, or why — only that the UA + referrer combination is the
// one reliable tell (rare for genuine visitors), and that it spans enough IPs that
// blocklisting by address isn't practical.
//
// For matching requests we return an empty 200 instead of the page. The point isn't to
// stop the requests — we don't know whether anything we return changes their behavior —
// it's that the response carries no HTML and no client-side Plausible script, so this
// traffic stays out of Plausible and doesn't skew the trending-articles widget.

// True when the UA looks like a plain Linux desktop Chrome browser (the shape the bot
// sends: "Mozilla/5.0 (X11; Linux x86_64) … Chrome/… Safari/537.36"). Matches the
// family rather than a specific Chrome version, so bumping the version doesn't evade it.
// Excludes user agents that identify a different browser (Edge, Opera, Brave, Firefox)
// or a self-identified bot/crawler — real Googlebot/Bingbot/etc. self-identify here and
// don't send a www.google.com referrer anyway.
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

// True when the referrer's host is a Google domain. Host-based so query strings and
// paths don't matter; a missing or malformed referrer parses as "not Google".
function isGoogleReferrer(referer: string): boolean {
  if (!referer) return false;
  try {
    const host = new URL(referer).hostname.toLowerCase();
    return host === 'www.google.com' || host === 'google.com';
  } catch {
    return false;
  }
}

// One pipe-separated request log line: the given lead-in parts, then the requester's
// referrer, user agent, IP, and geo (when known). Mirrors the format of the
// known-agents edge function (web/netlify/edge-functions/known-agents.ts) so blocked
// requests read the same way as the rest of the edge logs. context.ip is the
// visitor's origin IP address.
function requestLogLine(
  request: Request,
  context: Context,
  ...parts: (string | null | undefined)[]
): string {
  const geo =
    context.geo?.city && context.geo?.country?.name
      ? `${context.geo.city}, ${context.geo.country.name}`
      : context.geo?.city || context.geo?.country?.name;
  return [
    ...parts,
    request.headers.get('Referer'),
    request.headers.get('User-Agent'),
    context.ip,
    geo,
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
        '→ 200'
      )
    );
    // no-store so this empty response is never cached at the edge and can't leak onto a
    // shared cache entry for this URL that would then be served to legitimate visitors.
    // (A 200 is cacheable by default, so this matters more here than it would for an error.)
    return new Response(null, {
      status: 200,
      headers: {
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
