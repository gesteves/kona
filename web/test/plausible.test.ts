import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { handlePlausible } from '../src/plausible';
import { makeCtx, interceptFetch } from './helpers';

const SCRIPT_UPSTREAM = 'https://cdn.test/js/pa-abc.js';
const env = { PLAUSIBLE_SCRIPT_URL: SCRIPT_UPSTREAM } as Env;

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
    interceptFetch(
      'GET',
      SCRIPT_UPSTREAM,
      () =>
        new Response('window.plausible=function(){}', {
          headers: {
            'content-type': 'application/javascript',
            'set-cookie': 'sid=1; Path=/',
            'cache-control': 'public, max-age=3600',
          },
        })
    );

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

  it('normalizes the script cache key so a junk query cannot mint unbounded cache entries', async () => {
    interceptFetch(
      'GET',
      SCRIPT_UPSTREAM,
      () =>
        new Response('window.plausible=function(){}', {
          headers: { 'content-type': 'application/javascript' },
        })
    );

    await handlePlausible(
      new Request('https://www.example.com/pa/script.js?x=random'),
      env,
      makeCtx()
    );

    // Both the lookup and the store use the bare path — not the inbound URL with its query.
    const [matched] = vi.mocked(caches.default.match).mock.calls[0];
    expect((matched as Request).url).toBe(
      'https://www.example.com/pa/script.js'
    );
    const [stored] = vi.mocked(caches.default.put).mock.calls[0];
    expect((stored as Request).url).toBe(
      'https://www.example.com/pa/script.js'
    );
  });

  it('hands back a no-op 200 script when the upstream script errors (never a broken <script>)', async () => {
    interceptFetch(
      'GET',
      SCRIPT_UPSTREAM,
      () => new Response('upstream down', { status: 503 })
    );

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
    const upstream = interceptFetch(
      'POST',
      'https://plausible.io/api/event',
      () => new Response('', { status: 202 })
    );

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
    const sent = upstream.request!.headers;
    expect(sent.get('cookie')).toBeNull();
    expect(sent.get('x-forwarded-for')).toBe('203.0.113.9');
  });

  it('answers a HEAD probe for the script without a body, still going through the cache', async () => {
    interceptFetch(
      'GET',
      SCRIPT_UPSTREAM,
      () =>
        new Response('window.plausible=function(){}', {
          headers: { 'content-type': 'application/javascript' },
        })
    );

    const res = await handlePlausible(
      new Request('https://www.example.com/pa/script.js', { method: 'HEAD' }),
      env,
      makeCtx()
    );

    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toBe('application/javascript');
    expect(await res.text()).toBe('');
    // The miss still populates the cache (under the normalized GET key), so a HEAD probe
    // never costs an extra upstream fetch on the next GET.
    expect(vi.mocked(caches.default.put)).toHaveBeenCalled();
  });

  it('405s a non-GET/HEAD to the script path without touching the upstream', async () => {
    // No intercept registered: reaching the upstream would throw an unmocked-fetch error.
    const res = await handlePlausible(
      new Request('https://www.example.com/pa/script.js', { method: 'POST' }),
      env,
      makeCtx()
    );
    expect(res.status).toBe(405);
    expect(res.headers.get('allow')).toBe('GET, HEAD');
  });

  it('405s a non-POST to the event path without touching the upstream', async () => {
    const res = await handlePlausible(
      new Request('https://www.example.com/pa/event'),
      env,
      makeCtx()
    );
    expect(res.status).toBe(405);
    expect(res.headers.get('allow')).toBe('POST');
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
