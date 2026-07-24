// Fallthrough page server: returns the static page from the asset layer unchanged. Everything
// that isn't a widget/contact or Plausible route lands here — which, given run_worker_first is a
// positive allowlist (wrangler.jsonc), is nothing in practice.
export async function servePage(request: Request, env: Env): Promise<Response> {
  return env.ASSETS.fetch(request);
}
