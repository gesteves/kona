// Shared test helpers: a no-op ExecutionContext and env builders. Handlers take (request, env[,
// ctx]) and only touch the bindings they need, so tests pass hand-built envs and control every
// dependency (ASSETS is a stub; KONA_API_URL / PLAUSIBLE_SCRIPT_URL point at mocked origins).

// Background work handlers pass to ctx.waitUntil() (e.g. the Plausible script cache write) is
// collected here so setup.ts can drain it after each test — otherwise an in-flight caches.default
// write races the pool's per-test storage teardown and logs a spurious abort.
export const pendingWaits: Promise<unknown>[] = [];

export const makeCtx = (): ExecutionContext =>
  ({
    waitUntil(promise: Promise<unknown>) {
      pendingWaits.push(Promise.resolve(promise).catch(() => {}));
    },
    passThroughOnException() {},
  }) as unknown as ExecutionContext;

// An ASSETS binding stub that returns a fixed Response for any request.
export const assetsReturning = (response: () => Response): Env['ASSETS'] =>
  ({ fetch: async () => response() }) as unknown as Env['ASSETS'];

// A minimal Atom feed with two build-baked feed permalinks carrying the utm cluster (one plain,
// one with a tag campaign) plus an in-content utm_source that must never be touched.
export const FEED_XML = [
  '<?xml version="1.0" encoding="utf-8"?>',
  '<feed xmlns="http://www.w3.org/2005/Atom">',
  '  <entry><link href="https://www.example.com/2026/06/26/post/?utm_source=Feed&amp;utm_medium=feed"/></entry>',
  '  <entry><link href="https://www.example.com/tagged/running/?utm_source=Feed&amp;utm_medium=feed&amp;utm_campaign=running"/></entry>',
  '  <entry><summary>See https://elsewhere.example/x?utm_source=newsletter for more.</summary></entry>',
  '</feed>',
].join('\n');

export const feedResponse = (): Response =>
  new Response(FEED_XML, {
    status: 200,
    headers: { 'content-type': 'application/xml; charset=utf-8' },
  });
