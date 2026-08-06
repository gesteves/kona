/** Fallthrough page server: returns the static page from the asset layer unchanged. */
export async function servePage(request: Request, env: Env): Promise<Response> {
  return env.ASSETS.fetch(request);
}
