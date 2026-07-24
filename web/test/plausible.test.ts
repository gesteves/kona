import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { fetchMock } from 'cloudflare:test';
import { handlePlausible } from '../src/plausible';
import { makeCtx } from './helpers';

const SCRIPT_UPSTREAM = 'https://cdn.test/js/pa-abc.js';
const env = { PLAUSIBLE_SCRIPT_URL: SCRIPT_UPSTREAM } as Env;

type Captured = { headers: Record<string, string | string[]> };
const header = (c: Captured, name: string): string | undefined => {
  const v = c.headers[name.toLowerCase()];
  return Array.isArray(v) ? v[0] : v;
};

describe('handlePlausible', () => {
  // getScript reads/writes caches.default. Stub both so tests never touch real (per-test isolated)
  // Cache storage: that write otherwise trips a miniflare isolated-storage teardown bug (a
  // .sqlite-shm WAL file) that fails the run in CI. `match` → miss forces the upstream path;
  // `put` → no-op. We're asserting the proxy/response behavior, not the caching itself.
  beforeEach(() => {
    vi.spyOn(caches.default, 'match').mockResolvedValue(undefined);
    vi.spyOn(caches.default, 'put').mockResolvedValue(undefined);
  });
  afterEach(() => vi.restoreAllMocks());

  it('404s every path when PLAUSIBLE_SCRIPT_URL is unset (site built without analytics)', async () => {
    const res = await handlePlausible(
      new Request('https://www.example.com/pa/script.js'),
      {} as Env,
      makeCtx()
    );
    expect(res.status).toBe(404);
  });

  it('proxies the script, stripping Set-Cookie so caches.default.put cannot throw', async () => {
    fetchMock
      .get('https://cdn.test')
      .intercept({ path: '/js/pa-abc.js' })
      .reply(200, 'window.plausible=function(){}', {
        headers: {
          'content-type': 'application/javascript',
          'set-cookie': 'sid=1; Path=/',
          'cache-control': 'public, max-age=3600',
        },
      });

    const res = await handlePlausible(
      new Request('https://www.example.com/pa/script.js'),
      env,
      makeCtx()
    );
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toBe('application/javascript');
    expect(res.headers.get('set-cookie')).toBeNull();
    expect(await res.text()).toBe('window.plausible=function(){}');
  });

  it('hands back a no-op 200 script when the upstream script errors (never a broken <script>)', async () => {
    fetchMock
      .get('https://cdn.test')
      .intercept({ path: '/js/pa-abc.js' })
      .reply(503, 'upstream down');

    const res = await handlePlausible(
      new Request('https://www.example.com/pa/script.js'),
      env,
      makeCtx()
    );
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toBe('application/javascript');
    expect(await res.text()).toBe('');
  });

  it('forwards the event POST upstream, dropping cookies and adding X-Forwarded-For', async () => {
    let captured!: Captured;
    fetchMock
      .get('https://plausible.io')
      .intercept({ path: '/api/event', method: 'POST' })
      .reply((opts) => {
        captured = opts as unknown as Captured;
        return { statusCode: 202, data: '' };
      });

    const res = await handlePlausible(
      new Request('https://www.example.com/pa/event', {
        method: 'POST',
        headers: {
          cookie: 'a=b',
          'cf-connecting-ip': '203.0.113.9',
          'content-type': 'text/plain',
        },
        body: '{"n":"pageview","d":"example.com"}',
      }),
      env,
      makeCtx()
    );

    expect(res.status).toBe(202);
    expect(header(captured, 'cookie')).toBeUndefined();
    expect(header(captured, 'x-forwarded-for')).toBe('203.0.113.9');
  });

  it('404s an unknown /pa/ path', async () => {
    const res = await handlePlausible(
      new Request('https://www.example.com/pa/nope'),
      env,
      makeCtx()
    );
    expect(res.status).toBe(404);
  });
});
