import { handleApi } from './api-proxy';
import { withSecurityHeaders } from './headers';
import { requestLogLine } from './log';
import { handleOg, isOgPath } from './og';
import { handlePlausible } from './plausible';
import { servePage } from './serve-page';

// Worker entry point. Only the paths in wrangler.jsonc's run_worker_first allowlist reach this
// code; everything else is served straight from the static asset layer.
export default {
  async fetch(
    request: Request,
    env: Env,
    ctx: ExecutionContext
  ): Promise<Response> {
    const { pathname } = new URL(request.url);

    // The handlers log their own failures; this only catches what escapes them, which would
    // otherwise be a bare platform 500 with nothing written anywhere.
    try {
      // /api/contact is claimed explicitly, not /api/*, so the other origin-only /api endpoints
      // stay unreachable from the browser.
      if (pathname.startsWith('/widgets/') || pathname === '/api/contact') {
        return await handleApi(request, env);
      }
      if (pathname.startsWith('/pa/'))
        return await handlePlausible(request, env, ctx);
      if (isOgPath(pathname)) return await handleOg(request, env, ctx);

      // Defensive fallthrough: nothing else reaches the Worker under the allowlist, but drift
      // between it and this router should serve the page from assets rather than error.
      return await servePage(request, env);
    } catch (error) {
      console.error(
        requestLogLine(request, 'worker error', pathname, String(error))
      );
      // Secured like every other Worker-built response: this one is reachable as a top-level
      // document, so it must not be the one that ships without nosniff.
      return new Response('Internal Server Error', {
        status: 500,
        headers: withSecurityHeaders(
          new Headers({ 'content-type': 'text/plain; charset=utf-8' })
        ),
      });
    }
  },
};
