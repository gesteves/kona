import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import { WORKER_FIRST_GLOBS } from '../../src/routes.ts';

// The paths that come to the Worker are in two places: `run_worker_first` in wrangler.jsonc, which
// the platform reads, and src/routes.ts, which the code reads. No code can import wrangler.jsonc.
// A path in one list only is a route that never starts the Worker, or a handler that no request
// reaches, and nothing reports it. This file is in the node project, because a Worker test has no
// file system.

/** Parses JSON with `//` comments and commas at the end of a list. No string here holds `//`. */
function parseJsonc(text) {
  const plain = text
    .split('\n')
    .map((line) => line.replace(/^\s*\/\/.*$/, ''))
    .join('\n')
    .replace(/,(\s*[\]}])/g, '$1');
  return JSON.parse(plain);
}

describe('the route list of the Worker', () => {
  it('is the same in wrangler.jsonc and in src/routes.ts', () => {
    // The path comes from the Vitest root, which is web/. Refer to registration.test.js.
    const config = parseJsonc(
      readFileSync(resolve(process.cwd(), 'wrangler.jsonc'), 'utf8')
    );

    expect(config.assets.run_worker_first).toEqual(WORKER_FIRST_GLOBS);
  });
});
