// The ambient types for the tests only. tsconfig.test.json does NOT include src/env.d.ts, on
// purpose. Thus its Worker global declarations cannot conflict with @cloudflare/workers-types.
// This file declares the shape of the bindings of the app (Env) only. ExecutionContext, Fetcher,
// and caches.default come from those types.
interface Env {
  ASSETS: Fetcher;
  KONA_API_URL?: string;
  API_TOKEN?: string;
  PLAUSIBLE_SCRIPT_URL?: string;
}
