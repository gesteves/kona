import { describe, it, expect } from 'vitest';
import { fetchMock } from 'cloudflare:test';
import worker from '../src/index';
import { makeCtx, feedResponse } from './helpers';

const ORIGIN = 'https://origin.test';
const SCRIPT_UPSTREAM = 'https://cdn.test/pa.js';

// ASSETS serves the feed XML for feed paths and a plain marker for everything else, so routing to
// handleFeed vs servePage is distinguishable by the response.
const env = {
  KONA_API_URL: ORIGIN,
  API_TOKEN: 'T',
  PLAUSIBLE_SCRIPT_URL: SCRIPT_UPSTREAM,
  ASSETS: {
    fetch: async (req: Request) =>
      new URL(req.url).pathname.endsWith('/feed.xml')
        ? feedResponse()
        : new Response('ASSET', {
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
  it('routes /widgets/* to the api proxy', async () => {
    fetchMock
      .get(ORIGIN)
      .intercept({ path: '/widgets/weather/current', method: 'GET' })
      .reply(200, 'WIDGET');
    const res = await get('/widgets/weather/current');
    expect(await res.text()).toBe('WIDGET');
  });

  it('routes /api/contact to the api proxy', async () => {
    fetchMock
      .get(ORIGIN)
      .intercept({ path: '/api/contact', method: 'POST' })
      .reply(204, '');
    const res = await get('/api/contact', {
      method: 'POST',
      body: 'name=x',
      headers: { 'content-type': 'text/plain' },
    });
    expect(res.status).toBe(204);
  });

  it('routes /pa/script.js to the Plausible proxy', async () => {
    fetchMock
      .get('https://cdn.test')
      .intercept({ path: '/pa.js' })
      .reply(200, 'SCRIPT', {
        headers: { 'content-type': 'application/javascript' },
      });
    const res = await get('/pa/script.js');
    expect(res.headers.get('content-type')).toBe('application/javascript');
    expect(await res.text()).toBe('SCRIPT');
  });

  it('routes /feed.xml and nested tag feeds to the feed relabeler', async () => {
    for (const path of ['/feed.xml', '/tagged/running/feed.xml']) {
      const res = await get(path, { headers: { 'user-agent': 'Feedly' } });
      // The private Cache-Control is handleFeed's signature; servePage never sets it.
      expect(res.headers.get('cache-control')).toBe(
        'private, max-age=0, must-revalidate'
      );
      expect(await res.text()).toContain('utm_source=Feedly');
    }
  });

  it('serves everything else straight from the asset layer (no feed rewriting)', async () => {
    for (const path of ['/', '/about/', '/2026/06/26/some-post/']) {
      const res = await get(path);
      expect(await res.text()).toBe('ASSET');
      expect(res.headers.get('cache-control')).toBeNull();
    }
  });
});
