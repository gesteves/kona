import js from '@eslint/js';
import globals from 'globals';

// This covers the plain JavaScript only: the Stimulus app and its jsdom tests. `npm run check`
// does a type check of the TypeScript in src/ and test/ only, thus nothing else checks
// source/javascripts/**.
//
// ⚠️ This does NOT lint src/**/*.ts, on purpose. That needs typescript-eslint, which does not
// support TypeScript 7. Its rules call the compiler API, thus an override of its peer range
// would not work. `tsc --noEmit` and the Worker test suite check `src/` until it does.
//
// ⚠️ This has no format rules, on purpose. Prettier owns the layout, and `recommended` holds no
// stylistic rule. Thus the two do not overlap, and eslint-config-prettier is not necessary.
export default [
  {
    // ⚠️ `vendor/**` is necessary in CI, where `bundler-cache: true` puts the gems in
    // web/vendor/bundle/. ESLint lints each file that it walks into, with or without a `files:`
    // match, and some gems hold a .js file that is not a valid module. A local install puts the
    // gems outside the repo, thus only CI fails. `.prettierignore` and the paths of the `lint:js`
    // script do the same work.
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
    // The jsdom tests. They import each vitest helper, thus they need only the browser globals and
    // the node globals.
    files: ['test/browser/**/*.js'],
    ...js.configs.recommended,
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: { ...globals.browser, ...globals.node },
    },
  },
];
