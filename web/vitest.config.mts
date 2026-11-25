import { cloudflareTest } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';

// `npm test` runs TWO suites, and no one runtime can run both. Thus this file uses
// `test.projects`, and each project has its own plugins, environment, and setup file:
//
//   worker  — src/*.ts, the Cloudflare Worker, in workerd through @cloudflare/vitest-plugin.
//   browser — source/javascripts/**, the Stimulus and Turbo bundle, in jsdom.
//
// workerd has no `document`, no `window`, and no custom elements. jsdom has no `caches.default`
// and no `request.cf`.
//
// ⚠️ The FILE EXTENSION keeps the two `include` globs apart, and not the directory: the worker
// suite is `.test.ts`, and the browser suite is `.test.js`. Do not add a `.ts` test below
// test/browser/. The worker glob would take it and run it in workerd, where it fails at the
// first `document` with a message that does not show the cause.
export default defineConfig({
  test: {
    projects: [
      {
        // ── The Cloudflare Worker (src/) ──────────────────────────────────────────────────────
        // The pool does NOT read wrangler.jsonc, on purpose. Each test makes its own `env` and
        // mocks each outbound fetch, thus the pool needs no real binding. The `assets` binding
        // points at ./build, which is absent in the `checks` job of CI.
        plugins: [
          cloudflareTest({
            miniflare: {
              // The compatibility date of the TEST runtime. It is not the compatibility_date of
              // wrangler.jsonc. It must not be later than the date that the workerd of the pool
              // supports: with a later date, the pool gives a warning and uses an older one. The
              // tests use only fetch, Response, and the routing, thus the date changes no test.
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
        // No plugins: these are plain ES modules. jsdom gives the DOM. test/browser/setup.js adds
        // the APIs that jsdom does not have and that this code calls, and it resets the global
        // state and the DOM after each test.
        test: {
          name: 'browser',
          environment: 'jsdom',
          include: ['test/browser/**/*.test.js'],
          setupFiles: ['./test/browser/setup.js'],
          // This clears the call history of each mock before each test. A `vi.mock()` factory runs
          // ONE time for each file, thus each test of the file shares its vi.fn()s, and
          // `vi.restoreAllMocks()` does not reset them. Without this, `not.toHaveBeenCalled()`
          // depends on the tests before it. `mockReset` would also remove the implementations.
          clearMocks: true,
          // Each file gets its own jsdom, thus state at the module level cannot go from one file
          // to the next. In one file it can, and those suites use vi.resetModules().
          isolate: true,
        },
      },
    ],
  },
});
