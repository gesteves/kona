// One pipe-separated request log line: the given lead-in parts, then the requester's
// referrer, user agent, IP, geo, and ray. Shared by every route in the Worker.
//
// No fallback path: this Worker only ever runs behind the zone, so CF-Connecting-IP and
// CF-Ray are always present, and geo comes from request.cf (no managed transform needed).
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
