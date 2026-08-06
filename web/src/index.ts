import { handleApi } from './api-proxy';
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

    // /api/contact is claimed explicitly, not /api/*, so the other origin-only /api endpoints
    // stay unreachable from the browser.
    if (pathname.startsWith('/widgets/') || pathname === '/api/contact') {
      return handleApi(request, env);
    }
    if (pathname.startsWith('/pa/')) return handlePlausible(request, env, ctx);
    if (isOgPath(pathname)) return handleOg(request, env, ctx);

    // Defensive fallthrough: nothing else reaches the Worker under the allowlist, but drift
    // between it and this router should serve the page from assets rather than error.
    return servePage(request, env);
  },
};
