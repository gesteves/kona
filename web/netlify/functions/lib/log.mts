import type { Context } from '@netlify/functions';

// One pipe-separated request log line: the given lead-in parts, then the requester's
// user agent, IP, and geo (when known). Shared by the widget proxy and the OG image
// function. (This file isn't a function entry point — Netlify only treats
// <dir>/<dir>.mts or <dir>/index.mts as one — so it's import-only.)
export function requestLogLine(
  req: Request,
  context: Context,
  ...parts: (string | null | undefined)[]
): string {
  const geo =
    context.geo?.city && context.geo?.country?.name
      ? `${context.geo.city}, ${context.geo.country.name}`
      : context.geo?.city || context.geo?.country?.name;
  return [...parts, req.headers.get('User-Agent'), context.ip, geo]
    .filter(Boolean)
    .join(' | ');
}
