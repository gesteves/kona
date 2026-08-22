import { handleApi } from './api-proxy';
import { withSecurityHeaders } from './headers';
import { requestLogLine } from './log';
import { handleOg, isOgPath } from './og';
import { handlePlausible } from './plausible';
import { servePage } from './serve-page';

// The entry point of the Worker. Only the paths in the run_worker_first list of wrangler.jsonc come
// here. The static asset layer serves each other path.
export default {
  async fetch(
    request: Request,
    env: Env,
    ctx: ExecutionContext
  ): Promise<Response> {
    const { pathname } = new URL(request.url);

    // Each handler writes its own failures to the log. This code catches only a failure that gets
    // past a handler. Without it, such a failure is a platform 500 with no record.
    try {
      // This takes /api/contact and not /api/*, thus a browser cannot reach the other /api
      // endpoints, which are on the origin only.
      if (pathname.startsWith('/widgets/') || pathname === '/api/contact') {
        return await handleApi(request, env);
      }
      if (pathname.startsWith('/pa/'))
        return await handlePlausible(request, env, ctx);
      if (isOgPath(pathname)) return await handleOg(request, env, ctx);

      // A safety path: nothing else comes to the Worker under that list. But if the list and this
      // router do not agree, the code must serve the page from the assets and not give an error.
      return await servePage(request, env);
    } catch (error) {
      console.error(
        requestLogLine(request, 'worker error', pathname, String(error))
      );
      // This response gets the same headers as each other response from the Worker. A browser can
      // open it as a top-level document, thus it must not be the one response with no nosniff.
      return new Response('Internal Server Error', {
        status: 500,
        headers: withSecurityHeaders(
          new Headers({ 'content-type': 'text/plain; charset=utf-8' })
        ),
      });
    }
  },
};
