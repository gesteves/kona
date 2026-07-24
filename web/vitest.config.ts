import { defineWorkersConfig } from '@cloudflare/vitest-pool-workers/config';

// Runs the Worker unit tests (test/**) inside workerd via @cloudflare/vitest-pool-workers, so
// Request/Response/Headers, caches.default, request.cf and outbound-fetch mocking all behave as in
// production.
//
// Deliberately NOT wired to wrangler.jsonc: the tests build their own `env` objects and mock
// outbound fetch, so the pool needs no real bindings — in particular NOT the `assets` binding,
// which points at ./build (absent in the CI `checks` job, which runs before any build). We only
// mirror wrangler.jsonc's compatibility_date so the runtime matches what ships.
export default defineWorkersConfig({
  test: {
    include: ['test/**/*.test.ts'],
    setupFiles: ['./test/setup.ts'],
    poolOptions: {
      workers: {
        miniflare: {
          // The date the TEST runtime runs under — capped at what the pool's bundled workerd
          // supports (it warns and falls back otherwise). Distinct from production's
          // wrangler.jsonc compatibility_date; the tests exercise basic fetch/Response/routing,
          // so the exact date doesn't affect them. Bump when the pool's runtime advances.
          compatibilityDate: '2025-09-06',
        },
      },
    },
  },
});
