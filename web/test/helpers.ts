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
