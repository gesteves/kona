import type { Config, Context } from '@netlify/edge-functions';
import { requestLogLine } from './lib/log.ts';

// Records every page request server-side with Known Agents (the Dark Visitors company,
// using the DARK_VISITORS_ACCESS_TOKEN). This captures bots, AI
// crawlers, and LLM-referral traffic that never execute the client-side Plausible JS,
// so it complements — not replaces — that analytics. Mirrors the documented Cloudflare
// Worker pattern: time the request, then POST the visit in the background.
const KNOWN_AGENTS_API_URL = 'https://api.knownagents.com/visits';

// Don't forward headers that carry secrets or per-viewer identity to the analytics API.
const SENSITIVE_HEADERS = new Set(['cookie', 'authorization']);

function headersToObject(
  headers: Headers,
  omit?: Set<string>
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of headers) {
    if (omit?.has(key)) continue;
    out[key] = value;
  }
  return out;
}

// Never throws into the request path: any failure (network, non-2xx, bad token) is
// swallowed so tracking can't break or delay a page view.
async function trackVisit(
  request: Request,
  response: Response,
  durationMs: number,
  token: string
): Promise<void> {
  try {
    const url = new URL(request.url);
    await fetch(KNOWN_AGENTS_API_URL, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        // Include the query string: referral params (utm_*, ref, etc.) are how AI-agent
        // and LLM referral traffic is attributed.
        request_path: url.pathname + url.search,
        request_method: request.method,
        request_headers: headersToObject(request.headers, SENSITIVE_HEADERS),
        response_status_code: response.status,
        response_headers: {
          'content-type': response.headers.get('content-type') ?? '',
        },
        response_duration_in_milliseconds: durationMs,
      }),
    });
  } catch (error) {
    console.error('Known Agents tracking failed:', error);
  }
}

export default async function handler(
  request: Request,
  context: Context
): Promise<Response> {
  const token = Netlify.env.get('DARK_VISITORS_ACCESS_TOKEN');

  // Fail open: no token, or not a production deploy → pass straight through, untracked.
  // (Skipping previews/branch deploys keeps bot scans of those URLs out of the dataset.)
  // Read the deploy context from the Context object: the CONTEXT env var is build-time
  // only and is NOT present in the edge runtime, so reading it here always yields
  // undefined and would skip tracking everywhere — including production.
  if (!token || context.deploy.context !== 'production') {
    return context.next();
  }

  const start = Date.now();
  // The downstream static page / CDN response, returned to the client unchanged.
  const response = await context.next();
  const durationMs = Date.now() - start;

  const url = new URL(request.url);
  console.info(
    requestLogLine(
      request,
      context,
      `${request.method} ${url.pathname}`,
      `→ ${response.status}`
    )
  );

  // Background work: waitUntil keeps the edge worker alive to finish the POST *after*
  // the response is sent, so tracking adds no latency to the page.
  context.waitUntil(trackVisit(request, response, durationMs, token));

  return response;
}

export const config: Config = {
  // If this function ever crashes, never block the page: bypass the error so the request
  // chain continues and the downstream page/asset is returned unchanged. The crash is
  // still written to the edge function logs. This function only reports page views to
  // Known Agents — it must never interrupt rendering. (The fail-open token/context check
  // and the swallowed trackVisit errors above cover the expected paths; on: 'bypass' is
  // the backstop for any unexpected crash outside those guards.)
  onError: 'bypass',
  // Run on every request, then exclude everything that isn't a meaningful page view.
  path: '/*',
  excludedPath: [
    '/javascripts/*',
    '/stylesheets/*',
    '/images/*',
    '/fonts/*',
    '/widgets/*',
    '/og',
    '/plsbl/*',
    '/ifttt/*',
    '/.well-known/*',
    // No entry for image transformations: they're served from /cdn-cgi/*, which Cloudflare
    // answers at its own edge, so the request never reaches Netlify — or us.
    '/favicon.ico',
    '/*.png',
    '/*.jpg',
    '/*.jpeg',
    '/*.gif',
    '/*.svg',
    '/*.webp',
    '/*.avif',
    '/*.ico',
    '/*.woff',
    '/*.woff2',
    '/*.ttf',
    '/*.css',
    '/*.js',
    '/*.json',
    '/*.txt',
    '/*.map',
    '/*.xml',
  ],
};
