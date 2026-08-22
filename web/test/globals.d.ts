// The ambient types for the tests only. The production src/env.d.ts is NOT part of this compile, on
// purpose, because tsconfig.test.json includes test/** only. Thus its Worker global declarations
// cannot conflict with the @cloudflare/workers-types from the pool. This file declares the shape of
// the bindings of the app (Env) only. ExecutionContext, Fetcher, and caches.default come from the
// types of the pool.
interface Env {
  ASSETS: Fetcher;
  KONA_API_URL?: string;
  API_TOKEN?: string;
  PLAUSIBLE_SCRIPT_URL?: string;
}
