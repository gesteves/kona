// Runs axe-core over the pages that `rake build` wrote, and reports each violation.
//
// Usage: node test/a11y/run.mjs [root] [--all]
//   root   The directory of the build. The default is `build`.
//   --all  Check each HTML page, and not the sample below.
//
// ⚠️ This reads the STATIC HTML, and it runs no script in the page. That is what a crawler and the
// first render see. Thus each widget is still its skeleton here, which is correct: the skeleton is
// what a reader gets before the fragment arrives, and it must be accessible by itself.
//
// ⚠️ jsdom has no layout, thus a rule that needs a box gives no true result. `color-contrast` is
// off for that reason, and not because contrast does not matter. Check the colors in a browser.
//
// ⚠️ Nothing here stops a deploy. Refer to the accessibility job in .github/workflows/web.yml.

import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, relative } from 'node:path';
import { glob } from 'node:fs/promises';
import { JSDOM } from 'jsdom';

const require = createRequire(import.meta.url);
const AXE_SOURCE = await readFile(require.resolve('axe-core/axe.min.js'), 'utf8');

// A rule that needs a rendered box. jsdom reports these incorrectly.
const DISABLED_RULES = ['color-contrast'];

// Report a violation at these levels only. `minor` is mostly advice.
const REPORTED_IMPACTS = new Set(['serious', 'critical']);

// One page for each template. A page that the build did not write is not an error: a template
// renders only when Contentful holds an entry for it.
const SAMPLE = [
  'index.html',
  'about/index.html',
  'contact/index.html',
  'blog/index.html',
  '404.html',
];

/**
 * The first page below a directory, thus the sample covers an article, a Short, and a tag archive
 * without a slug in this file.
 * @param {string} root The build directory.
 * @param {string} pattern A glob, relative to the root.
 * @returns {Promise<string[]>} At most one path, relative to the root.
 */
async function firstMatch(root, pattern) {
  for await (const match of glob(pattern, { cwd: root })) {
    return [match];
  }
  return [];
}

/**
 * @param {string} root The build directory.
 * @param {boolean} all True to check each page.
 * @returns {Promise<string[]>} The pages to check, relative to the root.
 */
async function pagesToCheck(root, all) {
  if (all) {
    const found = [];
    for await (const match of glob('**/*.html', { cwd: root })) {
      found.push(match);
    }
    return found.sort();
  }
  const sample = SAMPLE.filter((page) => existsSync(join(root, page)));
  const article = await firstMatch(root, '20*/*/*/*/index.html');
  const archive = await firstMatch(root, 'tagged/*/index.html');
  return [...sample, ...article, ...archive];
}

/**
 * Runs axe over one page.
 * @param {string} root The build directory.
 * @param {string} page The path of the page, relative to the root.
 * @returns {Promise<object[]>} The violations at a reported level.
 */
async function checkPage(root, page) {
  const html = await readFile(join(root, page), 'utf8');
  // `outside-only` gives the window an `eval` for the axe source, and it runs no script of the
  // page itself.
  const dom = new JSDOM(html, {
    url: 'https://example.com/',
    runScripts: 'outside-only',
    pretendToBeVisual: true,
  });
  try {
    dom.window.eval(AXE_SOURCE);
    const results = await dom.window.axe.run(dom.window.document, {
      rules: Object.fromEntries(
        DISABLED_RULES.map((rule) => [rule, { enabled: false }])
      ),
    });
    return results.violations.filter((v) => REPORTED_IMPACTS.has(v.impact));
  } finally {
    dom.window.close();
  }
}

const args = process.argv.slice(2);
const all = args.includes('--all');
const root = args.find((a) => !a.startsWith('--')) || 'build';

if (!existsSync(root)) {
  console.error(
    `No build at ${relative(process.cwd(), root) || root}. Run \`bundle exec rake build\` first.`
  );
  process.exit(2);
}

const pages = await pagesToCheck(root, all);
if (pages.length === 0) {
  console.error(`No HTML pages below ${root}.`);
  process.exit(2);
}

let total = 0;
for (const page of pages) {
  const violations = await checkPage(root, page);
  total += violations.length;
  if (violations.length === 0) {
    console.log(`✅ /${page}`);
    continue;
  }
  console.log(`❎ /${page}`);
  for (const violation of violations) {
    console.log(`   [${violation.impact}] ${violation.id}: ${violation.help}`);
    console.log(`   ${violation.helpUrl}`);
    for (const node of violation.nodes.slice(0, 3)) {
      console.log(`     ${node.html.replace(/\s+/g, ' ').slice(0, 160)}`);
    }
    if (violation.nodes.length > 3) {
      console.log(`     …and ${violation.nodes.length - 3} more`);
    }
  }
}

console.log(
  `\n${pages.length} page(s) checked, ${total} violation type(s) at serious or critical.`
);
process.exit(total === 0 ? 0 : 1);
