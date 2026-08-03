import { handleApi } from './api-proxy';
import { handleOg, OG_PATH } from './og';
import { handlePlausible } from './plausible';
import { servePage } from './serve-page';

// Entry point. Only the paths in wrangler.jsonc's run_worker_first allowlist reach this code —
// the widget/contact proxy, the Plausible proxy, and the OG card renderer. Everything else
// (every HTML page, fingerprinted assets, images, the sitemap, the feeds, .well-known, 404s) is
// served straight from the static asset layer without invoking the Worker at all.
export default {
  async fetch(
    request: Request,
    env: Env,
    ctx: ExecutionContext
  ): Promise<Response> {
    const { pathname } = new URL(request.url);

    // The kona-api proxy: widget fragments (GET) and the contact-form POST. Both authenticate
    // to the origin with the injected bearer; /api/contact also forwards the real visitor
    // signal and its no-JS redirect (see api-proxy.ts). /api/contact is claimed explicitly,
    // NOT /api/*, so the other origin-only /api endpoints stay unreachable from the browser.
    // Static assets serve only GET/HEAD, so the /api/contact POST needs the Worker to reach
    // the origin at all; a GET to it falls through to servePage (renders a 404 page).
    if (pathname.startsWith('/widgets/') || pathname === '/api/contact') {
      return handleApi(request, env);
    }
    if (pathname.startsWith('/pa/')) return handlePlausible(request, env, ctx);

    // The on-demand Open Graph card for pages with no cover image. Reads the page out of the
    // static assets through the ASSETS binding and renders its og:title as a PNG (see og.ts).
    if (pathname === OG_PATH) return handleOg(request, env, ctx);

    // Defensive fallthrough. With the positive run_worker_first allowlist (wrangler.jsonc), the
    // only paths that reach the Worker are the dynamic routes above — page views are served
    // straight from the asset layer and never get here. This stays as a safety net so a drift
    // between the allowlist and this router serves the page from assets rather than erroring.
    return servePage(request, env);
  },
};
