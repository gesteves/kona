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
          compatibilityDate: '2026-07-01',
        },
      },
    },
  },
});
