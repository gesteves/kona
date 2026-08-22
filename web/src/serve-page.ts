/** The last page handler: it returns the static page from the asset layer with no change. */
export async function servePage(request: Request, env: Env): Promise<Response> {
  return env.ASSETS.fetch(request);
}
