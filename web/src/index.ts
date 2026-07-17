import { handleWidgets } from './widgets';
import { handlePlausible } from './plausible';
import { handleContact } from './contact';
import { handleFeed } from './feed-source';
import { servePage } from './known-agents';

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

    if (pathname.startsWith('/widgets/')) return handleWidgets(request, env);
    if (pathname.startsWith('/plsbl/'))
      return handlePlausible(request, env, ctx);

    // The main feed and every per-tag feed (`<tag path>feed.xml`, nested to any depth). The
    // `/feed.xml` suffix — with its leading slash — matches both without catching a stray
    // `…somethingfeed.xml`. handleFeed relabels utm_source per reader (see feed-source.ts).
    if (pathname.endsWith('/feed.xml')) return handleFeed(request, env);

    // The contact form POST (workstream: replace Netlify Forms). Static assets serve only
    // GET/HEAD, so /contact needs its run_worker_first entry for the POST to get here at
    // all; a GET falls through to servePage and renders the page like any other.
    if (
      (pathname === '/contact' || pathname === '/contact/') &&
      request.method === 'POST'
    ) {
      return handleContact(request, env);
    }

    // Everything else that reaches the Worker is a page view: serve it from the asset
    // layer and record the visit with Known Agents.
    return servePage(request, env, ctx);
  },
};
