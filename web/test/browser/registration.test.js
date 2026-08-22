import { readFileSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

// A check on the entry point of the bundle, and not on the behavior of one controller.
//
// index.js is the only place that makes a controller available to the markup. A new controller that
// nobody adds there fails in the quietest way in this code: the `data-controller` attribute does
// nothing. There is no error, there is no log line, and the page renders. The feature simply does
// not occur. An import of index.js for this check is not possible, because it loads the full Web
// Awesome Pro theme and registers twelve custom elements. Thus this file reads the source text.

// The path comes from the Vitest root, which is web/, and not from import.meta.url. In the jsdom
// environment, import.meta.url is an http:// URL, and node:fs refuses that.
const STIMULUS_DIR = resolve(process.cwd(), 'source/javascripts/stimulus');
const TEST_DIR = resolve(process.cwd(), 'test/browser');

const indexSource = readFileSync(join(STIMULUS_DIR, 'index.js'), 'utf8');

const controllerFiles = readdirSync(join(STIMULUS_DIR, 'controllers'))
  .filter((file) => file.endsWith('_controller.js'))
  .sort();

/** back_to_top_controller.js gives back-to-top. */
const identifierFor = (file) =>
  file.replace(/_controller\.js$/, '').replace(/_/g, '-');

/**
 * Each `<application>.register('id', ClassName)` in index.js, as [identifier, className].
 * The match on the receiver is wide, on purpose: this code reads index.js as text, thus a match on
 * one variable name would make a change to that name look like a loss of each controller.
 */
const registrations = [
  ...indexSource.matchAll(/\b\w+\.register\(\s*'([^']+)'\s*,\s*(\w+)\s*\)/g),
].map((match) => [match[1], match[2]]);

/** Each `import ClassName from './controllers/file'` in index.js, as [className, file]. */
const imports = new Map(
  [
    ...indexSource.matchAll(
      /import\s+(\w+)\s+from\s+'\.\/controllers\/([\w]+)'/g
    ),
  ].map((match) => [match[1], `${match[2]}.js`])
);

describe('controller registration', () => {
  it('finds the controllers to check', () => {
    // This checks the check: without it, a change to a name that broke the glob would make each
    // test below pass with no content.
    expect(controllerFiles.length).toBeGreaterThan(0);
  });

  it.each(controllerFiles)('registers %s', (file) => {
    const identifier = identifierFor(file);
    const registration = registrations.find(([id]) => id === identifier);

    expect(
      registration,
      `${file} is not registered in index.js as '${identifier}'`
    ).toBeDefined();
    expect(
      imports.get(registration[1]),
      `${registration[1]} is registered but imported from the wrong file`
    ).toBe(file);
  });

  it('registers nothing that does not exist', () => {
    const orphans = registrations
      .map(([, className]) => imports.get(className))
      .filter((file) => file && !controllerFiles.includes(file));

    expect(orphans).toEqual([]);
  });

  it('uses each identifier only once', () => {
    // A second registration with the same id replaces the first one, and gives no message.
    const identifiers = registrations.map(([id]) => id);

    expect(identifiers).toEqual([...new Set(identifiers)]);
  });

  it('has a test file for every controller', () => {
    // The suite that checks this suite.
    const tested = new Set(
      readdirSync(join(TEST_DIR, 'controllers'))
        .filter((file) => file.endsWith('.test.js'))
        .map((file) => file.replace('.test.js', ''))
    );
    const untested = controllerFiles
      .map((file) => file.replace('_controller.js', ''))
      .filter((name) => !tested.has(name));

    expect(untested).toEqual([]);
  });

  it('has a test file for every lib module', () => {
    const tested = new Set(
      readdirSync(join(TEST_DIR, 'lib'))
        .filter((file) => file.endsWith('.test.js'))
        .map((file) => file.replace('.test.js', ''))
    );
    const untested = readdirSync(join(STIMULUS_DIR, 'lib'))
      .filter((file) => file.endsWith('.js'))
      .map((file) => file.replace('.js', ''))
      .filter((name) => !tested.has(name));

    expect(untested).toEqual([]);
  });
});
