import { withSecurityHeaders } from './headers';

/** The methods of a route that only reads. */
export const READ_METHODS = ['GET', 'HEAD'];

/**
 * Makes a response with the security headers.
 *
 * ⚠️ Each response that the Worker makes goes through this function. src/headers.ts gives the
 * reason.
 * @param init The status and the other headers.
 */
export function securedResponse(
  body: BodyInit | null,
  init: ResponseInit = {}
): Response {
  const headers = withSecurityHeaders(new Headers(init.headers));
  return new Response(body, { ...init, headers });
}

/**
 * A 405 that names the methods of the route.
 * @param body The body. Each route keeps its own: a status line, an empty string, or nothing.
 * @param headers The other headers of the response.
 */
export function methodNotAllowed(
  allowed: string[],
  body: BodyInit | null = null,
  headers: Record<string, string> = {}
): Response {
  return securedResponse(body, {
    status: 405,
    headers: { ...headers, allow: allowed.join(', ') },
  });
}

/** Gives a HEAD request the response with no body. Each other method gets the response itself. */
export function withoutBodyForHead(
  request: Request,
  response: Response
): Response {
  return request.method === 'HEAD' ? new Response(null, response) : response;
}
