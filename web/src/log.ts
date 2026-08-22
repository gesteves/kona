/**
 * Makes a log line for a request, with a pipe between the fields: the given first fields, then the
 * referrer, the user agent, the IP, the geo data, and the ray of the requester.
 * @param parts The first fields. The code removes each blank one.
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
