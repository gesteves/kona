import { cloudflareTest } from '@cloudflare/vitest-pool-workers';
import { defineConfig } from 'vitest/config';

// `npm test` runs TWO suites, which need two mutually incompatible runtimes — hence
// `test.projects` rather than one flat config:
//
//   worker  — src/*.ts, the Cloudflare Worker, inside workerd via @cloudflare/vitest-pool-workers.
//   browser — source/javascripts/**, the Stimulus/Turbo bundle, inside jsdom.
//
// They can't share a config: the pool replaces the whole runtime with workerd, which has no
// `document`, no `window`, and no custom elements, so the controller tests can't run in it; and
// jsdom has no `caches.default` or `request.cf`, so the Worker tests can't run in jsdom. Each
// project therefore carries its own plugins, environment, and setup file. `vitest run` executes
// both and reports them separately by `name`.
//
// ⚠️ The two `include` globs are kept disjoint by FILE EXTENSION, not by directory: the worker
// suite is `.test.ts`, the browser suite is `.test.js` (matching the `.js` sources it exercises).
// The directory split is for humans. Don't add a `.ts` test under test/browser/ — the worker
// project's `test/**/*.test.ts` glob would claim it and run it in workerd, where it would fail on
// the first `document` reference for reasons that look nothing like the cause.
export default defineConfig({
  test: {
    projects: [
      {
        // ── The Cloudflare Worker (src/) ──────────────────────────────────────────────────────
        // Deliberately NOT wired to wrangler.jsonc: the tests build their own `env` objects and
        // mock outbound fetch, so the pool needs no real bindings — in particular NOT the `assets`
        // binding, which points at ./build (absent in the CI `checks` job, which runs before any
        // build). We only mirror wrangler.jsonc's compatibility_date so the runtime matches what
        // ships.
        //
        // ⚠️ This is the Vitest 4 shape. It used to be a `test.poolOptions.workers` block inside
        // `defineWorkersConfig` from `@cloudflare/vitest-pool-workers/config`; pool 0.18 dropped
        // that subpath export, and the same options object is now the argument to the
        // `cloudflareTest` *plugin* on a plain config. The pool version and the vitest major move
        // together — the pool peer-depends on `vitest@^4.1`, so neither can be bumped alone.
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
          name: 'worker',
          include: ['test/**/*.test.ts'],
          setupFiles: ['./test/setup.ts'],
        },
      },
      {
        // ── The browser bundle (source/javascripts/) ──────────────────────────────────────────
        // No plugins: these are plain ES modules that Vite transforms as-is. jsdom supplies the
        // DOM; test/browser/setup.js fills the handful of APIs jsdom omits that this code calls
        // (matchMedia, requestIdleCallback, scrollTo) and resets global/DOM state between tests.
        test: {
          name: 'browser',
          environment: 'jsdom',
          include: ['test/browser/**/*.test.js'],
          setupFiles: ['./test/browser/setup.js'],
          // Clears call history on every mock before each test. Needed because `vi.mock()`
          // factories are hoisted and run ONCE per file, so the vi.fn()s they return are shared
          // by every test in it — and `vi.restoreAllMocks()` only undoes spies, not those. Without
          // this, an assertion like `expect(trackEvent).not.toHaveBeenCalled()` passes or fails
          // based on what earlier tests in the file did. `clearMocks` (not `mockReset`) keeps the
          // factories' own implementations, e.g. `vi.fn().mockResolvedValue(true)`.
          clearMocks: true,
          // Each file gets its own jsdom, so module-level state in the code under test (the
          // live-update clock, pagefind's memoized loader, the search-tracking flag) can't leak
          // across files. Within a file it still can — those suites use vi.resetModules().
          isolate: true,
        },
      },
    ],
  },
});
