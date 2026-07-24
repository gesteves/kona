// Test-only ambient types. The production src/env.d.ts is intentionally NOT part of this compile
// (tsconfig.test.json includes test/** only), so its Worker-global shims can't collide with the
// @cloudflare/workers-types the pool provides. Re-declare just the app's binding shape (Env) here;
// ExecutionContext / Fetcher / caches.default come from the pool types.
interface Env {
  ASSETS: Fetcher;
  KONA_API_URL?: string;
  API_TOKEN?: string;
  PLAUSIBLE_SCRIPT_URL?: string;
}
