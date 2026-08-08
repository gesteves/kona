/**
 * The security headers the Worker routes can't inherit.
 *
 * ⚠️ These paths are claimed by `run_worker_first`, so they never touch the static asset layer
 * and never get the `/*` rules in `source/headers` — every one of them has to be re-set here.
 * Keep this list in step with that file's `/*` block. The CSP is deliberately not duplicated: it
 * is long, Report-Only, and describes documents, whereas these responses are HTML fragments and
 * PNGs that are never a top-level browsing context in normal use.
 *
 * @param headers The response headers to add to, mutated in place.
 * @returns The same Headers, for chaining into a Response init.
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
