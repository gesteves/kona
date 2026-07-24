// Fallthrough page server: returns the static page from the asset layer unchanged. Everything
// that isn't a widget/contact or Plausible route lands here — which, given run_worker_first is a
// positive allowlist (wrangler.jsonc), is nothing in practice.
//
// It logs nothing of its own: the invocation log already records the request, its status, and the
// client context, and this path has no failure mode of its own to explain (see the observability
// note in wrangler.jsonc).
export async function servePage(request: Request, env: Env): Promise<Response> {
  return env.ASSETS.fetch(request);
}
