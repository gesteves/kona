import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import worker from '../src/index';
import { makeCtx, interceptFetch } from './helpers';

const ORIGIN = 'https://origin.test';
const SCRIPT_UPSTREAM = 'https://cdn.test/pa.js';

// ASSETS returns a plain marker for every path, so a route that falls through to servePage is
// distinguishable (body 'ASSET') from one the Worker proxies itself.
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
  // The /pa/script.js route reaches getScript, which uses caches.default. Stub it so tests never
  // touch real per-test Cache storage (avoids the miniflare isolated-storage teardown bug in CI).
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

  // ⚠️ Kept to a 405, which is answered before the handler reaches its dynamic import of
  // ../src/og-render — a module the vitest pool cannot load (see test/og.test.ts). The og route's
  // real behavior is covered there, with the render injected.
  // Every card path ends in /og.png — the home page's card is /og.png itself, and every other
  // page's hangs off that page's path. Both shapes must reach the renderer (and both are claimed
  // in run_worker_first: "/og.png" + "/*/og.png").
  it.each(['/og.png', '/2026/06/26/some-post/og.png'])(
    'routes %s to the OG card renderer',
    async (path) => {
      const res = await get(path, { method: 'POST' });
      expect(res.status).toBe(405);
      expect(res.headers.get('allow')).toBe('GET, HEAD');
    }
  );

  it('serves everything else — including the feeds — straight from the asset layer', async () => {
    // The feeds used to be Worker-routed for per-reader utm rewriting; they are now plain assets.
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
