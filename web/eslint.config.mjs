import js from '@eslint/js';
import globals from 'globals';

// Covers the plain-JS surface only: the Stimulus app and its jsdom tests. That's the half of the
// codebase nothing else checked — `npm run check` typechecks src/ and test/ (tsconfig includes
// only those), so source/javascripts/** had neither a linter nor a typechecker.
//
// ⚠️ src/**/*.ts is deliberately NOT linted here. It would need typescript-eslint, which as of
// 8.66 declares `peer typescript@">=4.8.4 <6.1.0"` — this project is on TypeScript 7, the native
// compiler rewrite, and even the alphas haven't caught up. Its type-aware rules call the TS
// compiler API directly, so forcing the peer would be broken rather than merely unsupported.
// Revisit when typescript-eslint supports TS 7; `src/` meanwhile has `tsc --noEmit` and the
// worker test suite.
//
// ⚠️ No formatting rules, by design. Prettier owns layout; ESLint's stylistic rules were
// deprecated in v8.53 and are absent from `recommended`, so the two don't overlap and
// eslint-config-prettier isn't needed.
export default [
  {
    // ⚠️ `vendor/**` is load-bearing in CI and invisible locally: `bundler-cache: true` installs
    // gems into web/vendor/bundle/, and several ship .js (execjs runners, autoprefixer, Middleman's
    // jQuery fixtures) that isn't valid modern module syntax. ESLint lints every file it walks
    // into, including ones matching no `files:` block below, so without this the step fails on
    // other people's code. A local rbenv install puts gems outside the repo, so `eslint .` looks
    // clean here either way — hence the explicit paths in the `lint:js` script as well.
    // `.prettierignore` excludes `**/vendor/**` for the same reason; keep the two in step.
    ignores: ['build/**', 'tmp/**', 'node_modules/**', 'vendor/**'],
  },
  {
    files: ['source/javascripts/**/*.js'],
    ...js.configs.recommended,
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: globals.browser,
    },
  },
  {
    // jsdom tests. vitest helpers are imported explicitly (no `globals: true`), so only the
    // browser and node ambients are needed.
    files: ['test/browser/**/*.js'],
    ...js.configs.recommended,
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: { ...globals.browser, ...globals.node },
    },
  },
];
