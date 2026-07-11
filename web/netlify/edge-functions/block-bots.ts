import type { Config, Context } from '@netlify/edge-functions';

// Blocks a distributed bot that hammers article pages from a generic Linux desktop
// Chrome user agent while faking a Google search referrer. The traffic comes from
// hundreds of rotating IPs worldwide, so it can't be blocklisted by address — the
// only reliable signature is the UA + referrer combination, which is rare for genuine
// visitors. Returning a 403 (instead of the page) means the bot never receives the
// HTML or the client-side Plausible script, so it stops polluting analytics and
// skewing the trending-articles widget.

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
        '→ 403'
      )
    );
    // no-store so the denial is never cached at the edge and can't leak onto a shared
    // cache entry for this URL that would then be served to legitimate visitors.
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
