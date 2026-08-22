import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import worker from '../src/index';
import { makeCtx, interceptFetch } from './helpers';

const ORIGIN = 'https://origin.test';
const SCRIPT_UPSTREAM = 'https://cdn.test/pa.js';

// ASSETS returns the same marker for each path. Thus a route that goes to servePage has the body
// 'ASSET', and you can see the difference from a route that the Worker answers itself.
const env = {
  KONA_API_URL: ORIGIN,
  API_TOKEN: 'T',
  PLAUSIBLE_SCRIPT_URL: SCRIPT_UPSTREAM,
  ASSETS: {
    fetch: async () =>
      new Response('ASSET', {
        status: 200,
        headers: { 'content-type': 'text/html' },
      }),
  },
} as unknown as Env;

const get = (path: string, init?: RequestInit) =>
  worker.fetch(
    new Request(`https://www.example.com${path}`, init),
    env,
    makeCtx()
  );

describe('worker routing (src/index)', () => {
  // The /pa/script.js route calls getScript, which uses caches.default. Replace it, thus a test
  // never uses the true Cache storage of that test. This prevents the miniflare storage teardown
  // problem in CI.
  beforeEach(() => {
    vi.spyOn(caches.default, 'match').mockResolvedValue(undefined);
    vi.spyOn(caches.default, 'put').mockResolvedValue(undefined);
  });
  afterEach(() => vi.restoreAllMocks());

  it('routes /widgets/* to the api proxy', async () => {
    interceptFetch(
      'GET',
      `${ORIGIN}/widgets/weather/current`,
      () => new Response('WIDGET')
    );
    const res = await get('/widgets/weather/current');
    expect(await res.text()).toBe('WIDGET');
  });

  it('routes /api/contact to the api proxy', async () => {
    interceptFetch(
      'POST',
      `${ORIGIN}/api/contact`,
      () => new Response(null, { status: 204 })
    );
    const res = await get('/api/contact', {
      method: 'POST',
      body: 'name=x',
      headers: { 'content-type': 'text/plain' },
    });
    expect(res.status).toBe(204);
  });

  it('routes /pa/script.js to the Plausible proxy', async () => {
    interceptFetch(
      'GET',
      SCRIPT_UPSTREAM,
      () =>
        new Response('SCRIPT', {
          headers: { 'content-type': 'application/javascript' },
        })
    );
    const res = await get('/pa/script.js');
    expect(res.headers.get('content-type')).toBe('application/javascript');
    expect(await res.text()).toBe('SCRIPT');
  });

  // ⚠️ This test uses a 405, which the code answers before the handler does its dynamic import of
  // ../src/og-render. The vitest pool cannot load that module (refer to test/og.test.ts). The true
  // behavior of the og route is in that file, with the render as a parameter.
  // Each card path ends with /og.png. The card of the home page is /og.png itself, and the card of
  // each other page comes from the path of that page. Both shapes must reach the renderer, and
  // run_worker_first takes both: "/og.png" and "/*/og.png".
  it.each(['/og.png', '/2026/06/26/some-post/og.png'])(
    'routes %s to the OG card renderer',
    async (path) => {
      const res = await get(path, { method: 'POST' });
      expect(res.status).toBe(405);
      expect(res.headers.get('allow')).toBe('GET, HEAD');
    }
  );

  it('serves everything else — including the feeds — straight from the asset layer', async () => {
    // The Worker answered the feeds and changed the utm parameters for each reader. They are now
    // plain assets.
    for (const path of [
      '/',
      '/about/',
      '/2026/06/26/some-post/',
      '/feed.xml',
      '/tagged/running/feed.xml',
    ]) {
      const res = await get(path);
      expect(await res.text()).toBe('ASSET');
      expect(res.headers.get('cache-control')).toBeNull();
    }
  });
});
