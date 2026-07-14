import { requestLogLine } from './log';

// Serves a page from the static asset layer and records the visit server-side with Known
// Agents. This captures bots, AI crawlers, and LLM-referral traffic that never execute the
// client-side Plausible JS, so it complements — not replaces — that analytics.
//
// Adapted from Known Agents' official Cloudflare Worker guide
// (https://knownagents.com/docs/analytics/cloudflare-worker), with three deliberate
// deviations: the origin fetch is env.ASSETS.fetch (this Worker *is* the origin), the
// token comes from a secret binding instead of their hardcoded constant, and their JSON
// request/response body cloning for MCP / agentic-commerce calls is skipped — this site
// serves HTML. Their richer header field set (signature/agent/MCP headers) is kept.
const KNOWN_AGENTS_API_URL = 'https://api.knownagents.com/visits';

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
        response_status_code: response.status,
        response_headers: {
          'content-type': response.headers.get('content-type'),
          'mcp-session-id': response.headers.get('mcp-session-id'),
        },
        response_duration_in_milliseconds: durationMs,
        request_headers: {
          'cf-connecting-ip': request.headers.get('cf-connecting-ip'),
          'user-agent': request.headers.get('user-agent'),
          referer: request.headers.get('referer'),
          signature: request.headers.get('signature'),
          'signature-agent': request.headers.get('signature-agent'),
          'signature-input': request.headers.get('signature-input'),
          'api-version': request.headers.get('api-version'),
          'ucp-agent': request.headers.get('ucp-agent'),
          'mcp-session-id': request.headers.get('mcp-session-id'),
        },
      }),
    });
  } catch (error) {
    console.error('Known Agents tracking failed:', error);
  }
}

export async function servePage(
  request: Request,
  env: Env,
  ctx: ExecutionContext
): Promise<Response> {
  const start = Date.now();
  // The static page from the asset layer, returned to the client unchanged.
  const response = await env.ASSETS.fetch(request);
  const durationMs = Date.now() - start;

  const url = new URL(request.url);
  console.info(
    requestLogLine(
      request,
      `${request.method} ${url.pathname}`,
      `→ ${response.status}`
    )
  );

  // Track only real production traffic, gated on the request hostname — NOT an env flag:
  // preview versions share the production Worker's secrets and vars, so only the hostname
  // can tell a preview URL apart. (Skipping previews keeps bot scans of those URLs out of
  // the dataset.) No token → fail open, untracked.
  if (
    env.KNOWN_AGENTS_ACCESS_TOKEN &&
    env.SITE_HOSTNAME &&
    url.hostname === env.SITE_HOSTNAME
  ) {
    // Background work: waitUntil keeps the Worker alive to finish the POST *after* the
    // response is sent, so tracking adds no latency to the page.
    ctx.waitUntil(
      trackVisit(request, response, durationMs, env.KNOWN_AGENTS_ACCESS_TOKEN)
    );
  }

  return response;
}
