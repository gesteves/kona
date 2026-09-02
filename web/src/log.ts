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
    .filter((value): value is string => Boolean(value))
    .map(field)
    .join(' | ');
}

/** The most characters of one field. A header is client text and can be very long. */
const MAX_FIELD_LENGTH = 200;

/**
 * Makes one field safe for the line: no pipe, which is the separator, and a length limit. A
 * User-Agent of `x | 1.2.3.4` could otherwise write a false IP field.
 */
function field(value: string): string {
  const clean = value.replace(/[|\r\n]/g, ' ');
  return clean.length > MAX_FIELD_LENGTH
    ? `${clean.slice(0, MAX_FIELD_LENGTH)}…`
    : clean;
}
