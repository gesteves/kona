import { handleApi } from './api-proxy';
import { handlePlausible } from './plausible';
import { handleFeed } from './feed-source';
import { servePage } from './serve-page';

// Entry point. Only the paths listed in wrangler.jsonc's run_worker_first reach this code;
// everything else (fingerprinted assets, feeds, images, .well-known) is served straight
// from the static asset layer without invoking the Worker at all.
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

    // The main feed and every per-tag feed (`<tag path>feed.xml`, nested to any depth). The
    // `/feed.xml` suffix — with its leading slash — matches both without catching a stray
    // `…somethingfeed.xml`. handleFeed relabels utm_source per reader (see feed-source.ts).
    if (pathname.endsWith('/feed.xml')) return handleFeed(request, env);

    // Everything else that reaches the Worker is a page view: serve it from the asset layer.
    return servePage(request, env);
  },
};
