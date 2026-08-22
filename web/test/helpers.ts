// The shared test helpers: an ExecutionContext that does nothing, and functions that make an env.
// A handler takes (request, env[, ctx]) and uses only the bindings that it needs. Thus a test gives
// an env that it makes and controls each dependency. ASSETS is a stub, and KONA_API_URL and
// PLAUSIBLE_SCRIPT_URL point at test origins.

// This collects the background work that a handler gives to ctx.waitUntil(), for example the cache
// write of the Plausible script. Thus setup.ts can complete that work after each test. Without it,
// a caches.default write in progress races the storage teardown of the pool for that test, and the
// log gets an abort message that means nothing.
export const pendingWaits: Promise<unknown>[] = [];

export const makeCtx = (): ExecutionContext =>
  ({
    waitUntil(promise: Promise<unknown>) {
      pendingWaits.push(Promise.resolve(promise).catch(() => {}));
    },
    passThroughOnException() {},
  }) as unknown as ExecutionContext;

// An ASSETS binding stub that returns the same Response for each request.
export const assetsReturning = (response: () => Response): Env['ASSETS'] =>
  ({ fetch: async () => response() }) as unknown as Env['ASSETS'];

// The same as assetsReturning(), but it keeps each request that it gets. The og route makes its
// asset lookup from the origin of the request that comes in and from the `path` parameter, and a
// test must check that. assetsReturning() removes it.
export const assetsRecording = (
  response: () => Response
): { requests: Request[]; binding: Env['ASSETS'] } => {
  const requests: Request[] = [];
  return {
    requests,
    binding: {
      fetch: async (request: Request) => {
        requests.push(request);
        return response();
      },
    } as unknown as Env['ASSETS'],
  };
};

// ── Outbound fetch mocking ────────────────────────────────────────────────────────────────────
// This replaces the old `fetchMock` of the pool, which was an undici MockAgent through
// `cloudflare:test`. @cloudflare/vitest-pool-workers removed it in 0.18. The two supported
// replacements are MSW and a stub of `globalThis.fetch`. This is the stub, with the same rules that
// the tests need:
//
//   - a test registers each upstream call that it expects: the method and the absolute URL, with
//     the query. A query parameter that a test does not expect makes a *different* route, and that
//     is what lets the cache-key tests of the proxy check that the query never reaches the origin.
//   - each other call raises and does not reach the network, as the old `disableNetConnect()` did.
//   - an intercept that a test registers but never calls makes the test fail, as the old
//     `assertNoPendingInterceptors()` did.
//   - the handle from each intercept gives the request that the Worker sent. Thus a test reads a
//     true `Headers` object, and not the raw options object of undici.
//
// A handler runs in the isolate of the Worker. Thus a raise in a handler shows an origin that is
// down.

type FetchHandler = (request: Request) => Response | Promise<Response>;

export type FetchIntercept = {
  /** The upstream request from the code under test. It is undefined until that code sends it. */
  request?: Request;
  /** The body, which the code reads on arrival. At the time of the test, the stream is empty. */
  body?: string;
  calls: number;
};

type Route = FetchIntercept & { key: string; handler: FetchHandler };

const routes: Route[] = [];
const routeKey = (method: string, url: string) =>
  `${method.toUpperCase()} ${url}`;

// Registers one upstream call that a test expects. `url` is absolute and must match exactly.
export const interceptFetch = (
  method: string,
  url: string,
  handler: FetchHandler
): FetchIntercept => {
  const route: Route = { key: routeKey(method, url), handler, calls: 0 };
  routes.push(route);
  return route;
};

const dispatch = async (request: Request): Promise<Response> => {
  const key = routeKey(request.method, request.url);
  const route = routes.find((r) => r.key === key);
  if (route === undefined) {
    throw new Error(
      `Unmocked outbound fetch: ${key} — register it with interceptFetch(), or fix the code that sent it.`
    );
  }
  route.calls += 1;
  route.request = request;
  // The code holds the bytes and does not call .text(). workerd gives a warning when .text() reads
  // a body whose Content-Type is not text, and the contact form posts x-www-form-urlencoded. The
  // decode gives the same result.
  route.body = new TextDecoder().decode(await request.clone().arrayBuffer());
  return route.handler(request);
};

// This is an assignment and not vi.spyOn. Two suites call vi.restoreAllMocks() in their own
// afterEach, to remove their caches.default spies, and that would remove a spy here during a run.
export const installFetchMock = (): (() => void) => {
  const original = globalThis.fetch;
  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) =>
    dispatch(new Request(input as RequestInfo, init))) as typeof fetch;
  return () => {
    globalThis.fetch = original;
  };
};

// Empties the registry and makes the test fail if an intercept stays unused. Without this check,
// an old expectation looks the same as a test that passes.
export const resetFetchMock = (): void => {
  const unused = routes.filter((r) => r.calls === 0).map((r) => r.key);
  routes.length = 0;
  if (unused.length > 0) {
    throw new Error(
      `Fetch intercepts registered but never called: ${unused.join(', ')}`
    );
  }
};
