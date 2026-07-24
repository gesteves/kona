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

// ── Outbound fetch mocking ────────────────────────────────────────────────────────────────────
// Stands in for the pool's old `fetchMock` (an undici MockAgent reached through `cloudflare:test`),
// which @cloudflare/vitest-pool-workers dropped in 0.18. The supported replacements are MSW or
// stubbing `globalThis.fetch`; this is the latter, kept to the same contract the tests relied on:
//
//   - a test registers exactly the upstream calls it expects (method + absolute URL, query
//     included — a stray query param is a *different* route, which is what lets the proxy's
//     cache-key tests assert the query never reaches the origin),
//   - anything else throws instead of reaching the network (the old `disableNetConnect()`),
//   - an intercept that's registered but never called fails the test (the old
//     `assertNoPendingInterceptors()`),
//   - and the handle each intercept returns exposes the request the Worker actually sent, so
//     assertions read real `Headers` rather than undici's raw options blob.
//
// Handlers run in the Worker's own isolate, so throwing from one is how you simulate an origin
// that's down.

type FetchHandler = (request: Request) => Response | Promise<Response>;

export type FetchIntercept = {
  /** The upstream request the code under test made — undefined until it makes it. */
  request?: Request;
  /** Its body, read on arrival: by assertion time the request's own stream is spent. */
  body?: string;
  calls: number;
};

type Route = FetchIntercept & { key: string; handler: FetchHandler };

const routes: Route[] = [];
const routeKey = (method: string, url: string) =>
  `${method.toUpperCase()} ${url}`;

// Register one expected upstream call. `url` is absolute and matched exactly.
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
  // Buffered as bytes, not .text(): workerd warns when .text() is called on a body whose
  // Content-Type isn't texty (the contact form posts x-www-form-urlencoded), and the decode is
  // the same either way.
  route.body = new TextDecoder().decode(await request.clone().arrayBuffer());
  return route.handler(request);
};

// Plain assignment rather than vi.spyOn: two suites call vi.restoreAllMocks() in their own
// afterEach (to undo their caches.default spies), which would tear a spy here down mid-run.
export const installFetchMock = (): (() => void) => {
  const original = globalThis.fetch;
  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) =>
    dispatch(new Request(input as RequestInfo, init))) as typeof fetch;
  return () => {
    globalThis.fetch = original;
  };
};

// Clears the registry and fails the test if it left an intercept unused — a stale expectation
// otherwise looks exactly like a passing test.
export const resetFetchMock = (): void => {
  const unused = routes.filter((r) => r.calls === 0).map((r) => r.key);
  routes.length = 0;
  if (unused.length > 0) {
    throw new Error(
      `Fetch intercepts registered but never called: ${unused.join(', ')}`
    );
  }
};
