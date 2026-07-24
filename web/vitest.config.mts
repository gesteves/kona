import { cloudflareTest } from '@cloudflare/vitest-pool-workers';
import { defineConfig } from 'vitest/config';

// Runs the Worker unit tests (test/**) inside workerd via @cloudflare/vitest-pool-workers, so
// Request/Response/Headers, caches.default, request.cf and outbound-fetch mocking all behave as in
// production.
//
// Deliberately NOT wired to wrangler.jsonc: the tests build their own `env` objects and mock
// outbound fetch, so the pool needs no real bindings — in particular NOT the `assets` binding,
// which points at ./build (absent in the CI `checks` job, which runs before any build). We only
// mirror wrangler.jsonc's compatibility_date so the runtime matches what ships.
//
// ⚠️ This is the Vitest 4 shape. It used to be a `test.poolOptions.workers` block inside
// `defineWorkersConfig` from `@cloudflare/vitest-pool-workers/config`; pool 0.18 dropped that
// subpath export, and the same options object is now the argument to the `cloudflareTest` *plugin*
// on a plain `defineConfig`. The pool version and the vitest major move together — the pool peer-
// depends on `vitest@^4.1`, so neither can be bumped alone.
export default defineConfig({
  plugins: [
    cloudflareTest({
      miniflare: {
        // The date the TEST runtime runs under — capped at what the pool's bundled workerd
        // supports (it warns and falls back otherwise). Distinct from production's
        // wrangler.jsonc compatibility_date; the tests exercise basic fetch/Response/routing,
        // so the exact date doesn't affect them. Bump when the pool's runtime advances.
        compatibilityDate: '2025-09-06',
      },
    }),
  ],
  test: {
    include: ['test/**/*.test.ts'],
    setupFiles: ['./test/setup.ts'],
  },
});
