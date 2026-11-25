import { handleApi } from './api-proxy';
import { requestLogLine } from './log';
import { handleOg } from './og';
import { handlePlausible } from './plausible';
import { securedResponse } from './responses';
import {
  CONTACT_PATH,
  PLAUSIBLE_PREFIX,
  WIDGETS_PREFIX,
  isOgPath,
} from './routes';
import { servePage } from './serve-page';

// The entry point of the Worker. Only the paths of src/routes.ts come here. The static asset layer
// serves each other path.
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
      if (pathname.startsWith(WIDGETS_PREFIX) || pathname === CONTACT_PATH) {
        return await handleApi(request, env);
      }
      if (pathname.startsWith(PLAUSIBLE_PREFIX))
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
      return securedResponse('Internal Server Error', {
        status: 500,
        headers: { 'content-type': 'text/plain; charset=utf-8' },
      });
    }
  },
};
