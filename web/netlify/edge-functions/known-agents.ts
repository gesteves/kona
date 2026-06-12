import type { Config, Context } from '@netlify/edge-functions';

// Records every page request server-side with Known Agents (the Dark Visitors company,
// using the same DARK_VISITORS_ACCESS_TOKEN as robots.mts). This captures bots, AI
// crawlers, and LLM-referral traffic that never execute the client-side Plausible JS,
// so it complements — not replaces — that analytics. Mirrors the documented Cloudflare
// Worker pattern: time the request, then POST the visit in the background.
const KNOWN_AGENTS_API_URL = 'https://api.knownagents.com/visits';

// Don't forward headers that carry secrets or per-viewer identity to the analytics API.
const SENSITIVE_HEADERS = new Set(['cookie', 'authorization']);

function headersToObject(headers: Headers, omit?: Set<string>): Record<string, string> {
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
  token: string,
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
        request_path: url.pathname,
        request_method: request.method,
        request_headers: headersToObject(request.headers, SENSITIVE_HEADERS),
        response_status_code: response.status,
        response_headers: { 'content-type': response.headers.get('content-type') ?? '' },
        response_duration_in_milliseconds: durationMs,
      }),
    });
  } catch (error) {
    console.error('Known Agents tracking failed:', error);
  }
}

export default async function handler(request: Request, context: Context): Promise<Response> {
  const token = Deno.env.get('DARK_VISITORS_ACCESS_TOKEN');

  // Fail open: no token, or not a production deploy → pass straight through, untracked.
  // (Skipping previews/branch deploys keeps bot scans of those URLs out of the dataset.)
  if (!token || Deno.env.get('CONTEXT') !== 'production') {
    return context.next();
  }

  const start = Date.now();
  // The downstream static page / CDN response, returned to the client unchanged.
  const response = await context.next();
  const durationMs = Date.now() - start;

  // Background work: waitUntil keeps the edge worker alive to finish the POST *after*
  // the response is sent, so tracking adds no latency to the page.
  context.waitUntil(trackVisit(request, response, durationMs, token));

  return response;
}

export const config: Config = {
  // Run on every request, then exclude everything that isn't a real page view:
  // built assets, the other Netlify functions, the Plausible proxy, and feeds.
  path: '/*',
  excludedPath: [
    '/javascripts/*',
    '/stylesheets/*',
    '/images/*',
    '/fonts/*',
    '/api/*',
    '/og',
    '/robots.txt',
    '/plsbl/*',
    '/sitemap.xml',
    '/feed.xml',
    '/.well-known/*',
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
    '/*.xml',
    '/*.txt',
    '/*.map',
  ],
};
