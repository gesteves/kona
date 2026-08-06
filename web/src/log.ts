/**
 * Builds a pipe-separated request log line: the given lead-in parts, then the requester's
 * referrer, user agent, IP, geo, and ray.
 * @param parts Lead-in fields; blank ones are dropped.
 */
export function requestLogLine(
  request: Request,
  ...parts: (string | null | undefined)[]
): string {
  const cf = (request as { cf?: { city?: string; country?: string } }).cf;
  const geo = [cf?.city, cf?.country].filter(Boolean).join(', ');
  return [
    ...parts,
    request.headers.get('Referer'),
    request.headers.get('User-Agent'),
    request.headers.get('CF-Connecting-IP'),
    geo || undefined,
    request.headers.get('CF-Ray'),
  ]
    .filter(Boolean)
    .join(' | ');
}
