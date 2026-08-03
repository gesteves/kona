import { readFileSync, readdirSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';

// A guard on the bundle entry point rather than on any one controller's behaviour.
//
// index.js is the only place a controller becomes reachable from markup, and forgetting to add a
// new one there fails in the most quiet way this codebase has: the `data-controller` attribute is
// simply inert. Nothing errors, nothing logs, the page renders — the feature just doesn't happen.
// Importing index.js to check this isn't an option (it pulls in the whole Web Awesome Pro theme
// and registers a dozen custom elements), so this reads the source instead.

// Resolved from the Vitest root (web/) rather than from import.meta.url: under the jsdom
// environment that is an http:// URL, which node:fs rejects outright.
const STIMULUS_DIR = resolve(process.cwd(), 'source/javascripts/stimulus');
const TEST_DIR = resolve(process.cwd(), 'test/browser');

const indexSource = readFileSync(join(STIMULUS_DIR, 'index.js'), 'utf8');

const controllerFiles = readdirSync(join(STIMULUS_DIR, 'controllers'))
  .filter((file) => file.endsWith('_controller.js'))
  .sort();

/** back_to_top_controller.js → back-to-top */
const identifierFor = (file) =>
  file.replace(/_controller\.js$/, '').replace(/_/g, '-');

/** Every `Stimulus.register('id', ClassName)` in index.js, as [identifier, className]. */
const registrations = [
  ...indexSource.matchAll(/Stimulus\.register\(\s*'([^']+)'\s*,\s*(\w+)\s*\)/g),
].map((match) => [match[1], match[2]]);

/** Every `import ClassName from './controllers/file'` in index.js, as [className, file]. */
const imports = new Map(
  [
    ...indexSource.matchAll(
      /import\s+(\w+)\s+from\s+'\.\/controllers\/([\w]+)'/g
    ),
  ].map((match) => [match[1], `${match[2]}.js`])
);

describe('controller registration', () => {
  it('finds the controllers to check', () => {
    // Guards the guard: a rename that broke the glob would otherwise make every test below pass
    // vacuously.
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
    // A duplicate would silently win over the earlier registration.
    const identifiers = registrations.map(([id]) => id);

    expect(identifiers).toEqual([...new Set(identifiers)]);
  });

  it('has a test file for every controller', () => {
    // The suite that keeps this suite honest.
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
