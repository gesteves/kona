import { requestLogLine } from './log';

// Fallthrough page server: returns the static page from the asset layer unchanged, with a
// request log line. Everything that isn't a widget/contact, Plausible, or feed route lands
// here.
export async function servePage(request: Request, env: Env): Promise<Response> {
  const response = await env.ASSETS.fetch(request);

  const url = new URL(request.url);
  console.info(
    requestLogLine(
      request,
      `${request.method} ${url.pathname}`,
      `→ ${response.status}`
    )
  );

  return response;
}
