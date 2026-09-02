import { describe, it, expect } from 'vitest';
import { withSecurityHeaders } from '../src/headers';
import expected from './fixtures/security_headers.json';

// ⚠️ The fixture is the one list of the security headers. spec/lib/security_headers_spec.rb
// compares the `/*` block of source/headers.erb with the same file, thus the Worker routes and
// the asset layer cannot send a different set.
describe('withSecurityHeaders', () => {
  it('sets exactly the headers of the fixture, with the same values', () => {
    const headers = withSecurityHeaders(new Headers());
    const names = [...headers.keys()].sort();

    expect(names).toEqual(Object.keys(expected).sort());
    for (const [name, value] of Object.entries(expected)) {
      expect(headers.get(name), name).toBe(value);
    }
  });

  it('replaces a value that is already there and keeps the other headers', () => {
    const headers = withSecurityHeaders(
      new Headers({
        'x-frame-options': 'SAMEORIGIN',
        'content-type': 'text/plain',
      })
    );

    expect(headers.get('x-frame-options')).toBe('DENY');
    expect(headers.get('content-type')).toBe('text/plain');
  });
});
