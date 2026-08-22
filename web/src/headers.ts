/**
 * The security headers that the Worker routes cannot get from another place.
 *
 * ⚠️ `run_worker_first` takes these paths, thus they never reach the static asset layer and never
 * get the `/*` rules of `source/headers`. Each header must go here again. Keep this list the same
 * as the `/*` block of that file. The CSP is not here, on purpose: it is long, it is Report-Only,
 * and it describes a document. These responses are HTML fragments and PNGs, and in normal use they
 * are never a top-level browsing context.
 *
 * @param headers The response headers. This function changes them in place.
 * @returns The same Headers, for use in a Response init.
 */
export function withSecurityHeaders(headers: Headers): Headers {
  headers.set('referrer-policy', 'no-referrer-when-downgrade');
  headers.set('x-content-type-options', 'nosniff');
  headers.set('x-frame-options', 'DENY');
  headers.set('cross-origin-opener-policy', 'same-origin-allow-popups');
  headers.set(
    'permissions-policy',
    'accelerometer=(), camera=(), display-capture=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()'
  );
  headers.set(
    'strict-transport-security',
    'max-age=31536000; includeSubDomains'
  );
  return headers;
}
