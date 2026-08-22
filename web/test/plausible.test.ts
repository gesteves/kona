import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { handlePlausible } from '../src/plausible';
import { makeCtx, interceptFetch } from './helpers';

const SCRIPT_UPSTREAM = 'https://cdn.test/js/pa-abc.js';
const env = { PLAUSIBLE_SCRIPT_URL: SCRIPT_UPSTREAM } as Env;

describe('handlePlausible', () => {
  // getScript reads caches.default and writes to it. Replace both, thus a test never uses the true
  // Cache storage, which the pool keeps separate for each test. Without this, the write causes a
  // miniflare storage teardown problem with a .sqlite-shm WAL file, and the run fails in CI.
  // `match` gives a miss, which makes the code call the upstream service. `put` does nothing. These
  // tests check the proxy and the response, and not the cache.
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

    // The read and the write both use the path with no query, and not the URL that comes in.
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
    // The miss still puts the value in the cache, under the corrected GET key. Thus a HEAD request
    // does not cause a second upstream fetch at the next GET.
    expect(vi.mocked(caches.default.put)).toHaveBeenCalled();
  });

  it('405s a non-GET/HEAD to the script path without touching the upstream', async () => {
    // There is no intercept. A request to the upstream service would raise an unmocked-fetch
    // error.
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

  // ⚠️ run_worker_first takes /pa/*, thus it never gets the /* block of source/headers. This route
  // serves JavaScript that runs, from the origin of the site. Thus it is the route that needs
  // nosniff the most.
  describe('security headers', () => {
    function expectSecured(res: Response) {
      expect(res.headers.get('x-content-type-options')).toBe('nosniff');
      expect(res.headers.get('x-frame-options')).toBe('DENY');
      expect(res.headers.get('referrer-policy')).toBe(
        'no-referrer-when-downgrade'
      );
      expect(res.headers.get('strict-transport-security')).toBe(
        'max-age=31536000; includeSubDomains'
      );
    }

    it('sets them on the proxied script', async () => {
      interceptFetch(
        'GET',
        SCRIPT_UPSTREAM,
        () =>
          new Response('window.plausible=function(){}', {
            headers: {
              'content-type': 'application/javascript',
              'cache-control': 'public, max-age=3600',
            },
          })
      );

      expectSecured(
        await handlePlausible(
          new Request('https://www.example.com/pa/script.js'),
          env,
          makeCtx()
        )
      );
    });

    // These answer before an upstream fetch, thus they register no intercept.
    it.each([
      [
        'a 405 on the script path',
        'POST',
        'https://www.example.com/pa/script.js',
      ],
      ['a 405 on the event path', 'GET', 'https://www.example.com/pa/event'],
      ['an unknown /pa/ path', 'GET', 'https://www.example.com/pa/nope'],
      [
        'a 404 when analytics is unconfigured',
        'GET',
        'https://www.example.com/pa/script.js',
      ],
    ])('sets them on %s', async (label, method, url) => {
      const useEnv = label.includes('unconfigured') ? ({} as Env) : env;

      expectSecured(
        await handlePlausible(new Request(url, { method }), useEnv, makeCtx())
      );
    });

    it('sets them on the no-op script served when the upstream fails', async () => {
      interceptFetch(
        'GET',
        SCRIPT_UPSTREAM,
        () => new Response('', { status: 502 })
      );

      const res = await handlePlausible(
        new Request('https://www.example.com/pa/script.js'),
        env,
        makeCtx()
      );

      expect(res.status).toBe(200);
      expect(res.headers.get('x-content-type-options')).toBe('nosniff');
    });

    it("re-serves only an allowlist of the upstream's headers, not whatever its CDN set", async () => {
      interceptFetch(
        'GET',
        SCRIPT_UPSTREAM,
        () =>
          new Response('window.plausible=function(){}', {
            headers: {
              'content-type': 'application/javascript',
              'cache-control': 'public, max-age=3600',
              'set-cookie': 'sid=1; Path=/',
              vary: '*',
              'access-control-allow-origin': '*',
              'x-plausible-internal': 'leaked',
            },
          })
      );

      const res = await handlePlausible(
        new Request('https://www.example.com/pa/script.js'),
        env,
        makeCtx()
      );

            // The code keeps these: the browser needs them to run the script and to cache it.
      expect(res.headers.get('content-type')).toBe('application/javascript');
      expect(res.headers.get('cache-control')).toBe('public, max-age=3600');
      // The code removes these: each other header from the CDN of Plausible would go to the browser
      // under this origin and would stay in caches.default for its full TTL.
      expect(res.headers.get('set-cookie')).toBeNull();
      expect(res.headers.get('vary')).toBeNull();
      expect(res.headers.get('access-control-allow-origin')).toBeNull();
      expect(res.headers.get('x-plausible-internal')).toBeNull();
    });
  });
});
