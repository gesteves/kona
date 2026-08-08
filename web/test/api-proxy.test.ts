import { describe, it, expect } from 'vitest';
import { handleApi } from '../src/api-proxy';
import { interceptFetch } from './helpers';

const ORIGIN = 'https://origin.test';
const env = { KONA_API_URL: ORIGIN, API_TOKEN: 'SERVER_TOKEN' } as Env;

describe('handleApi — widgets (GET)', () => {
  it('injects the constant bearer, drops the client authorization and accept', async () => {
    const upstream = interceptFetch(
      'GET',
      `${ORIGIN}/widgets/weather/current`,
      () =>
        new Response('<div>weather</div>', {
          headers: {
            'content-type': 'text/html',
            'cache-control': 'public, max-age=0, stale-while-revalidate=300',
            'cdn-cache-control': 'public, max-age=300',
          },
        })
    );

    const res = await handleApi(
      new Request('https://www.example.com/widgets/weather/current', {
        headers: {
          accept: 'text/html',
          authorization: 'Bearer CLIENT_SNOOP',
          cookie: 'session=1',
        },
      }),
      env
    );

    expect(res.status).toBe(200);
    // Browser-facing Cache-Control passes through verbatim…
    expect(res.headers.get('cache-control')).toBe(
      'public, max-age=0, stale-while-revalidate=300'
    );
    // …but the edge policy is never forwarded to the browser.
    expect(res.headers.get('cdn-cache-control')).toBeNull();
    expect(await res.text()).toBe('<div>weather</div>');

    // Upstream request: server bearer injected (client's dropped), cookie dropped.
    const sent = upstream.request!.headers;
    expect(sent.get('authorization')).toBe('Bearer SERVER_TOKEN');
    expect(sent.get('cookie')).toBeNull();
    // accept is contact-only: it varies per browser and the edge cache key ignores it, so
    // forwarding it would break the "every viewer's upstream request is identical" invariant.
    expect(sent.get('accept')).toBeNull();
    // Widgets never forward the visitor signal — that's contact-only.
    expect(sent.get('x-kona-client-ip')).toBeNull();
    // Fragments are built from scratch here, so they carry their own security headers.
    expect(res.headers.get('x-content-type-options')).toBe('nosniff');
    expect(res.headers.get('x-frame-options')).toBe('DENY');
  });

  it('strips the query string so a junk param cannot bust the path-keyed edge cache', async () => {
    // Only the BARE path is intercepted, and intercepts match the full URL — query included. An
    // upstream request carrying the query would match nothing and throw, so this fails with an
    // unmocked-fetch error rather than silently passing.
    const upstream = interceptFetch(
      'GET',
      `${ORIGIN}/widgets/whoop`,
      () => new Response('<div>whoop</div>')
    );

    const res = await handleApi(
      new Request('https://www.example.com/widgets/whoop?bust=random'),
      env
    );

    expect(res.status).toBe(200);
    expect(await res.text()).toBe('<div>whoop</div>');
    expect(upstream.request!.url).toBe(`${ORIGIN}/widgets/whoop`);
  });

  it('forwards the origin ETag and answers If-None-Match itself with a 304', async () => {
    const upstream = interceptFetch(
      'GET',
      `${ORIGIN}/widgets/whoop`,
      () =>
        new Response('<div>whoop</div>', {
          headers: {
            'content-type': 'text/html',
            'cache-control': 'public, max-age=0, stale-while-revalidate=300',
            etag: 'W/"abc123"',
          },
        })
    );

    const res = await handleApi(
      new Request('https://www.example.com/widgets/whoop', {
        headers: { 'if-none-match': 'W/"abc123"' },
      }),
      env
    );

    expect(res.status).toBe(304);
    expect(await res.text()).toBe('');
    expect(res.headers.get('etag')).toBe('W/"abc123"');
    expect(res.headers.get('cache-control')).toBe(
      'public, max-age=0, stale-while-revalidate=300'
    );
    // The conditional is answered at the proxy, never forwarded upstream — a per-client
    // If-None-Match on the upstream request would shatter the shared edge cache entry.
    expect(upstream.request!.headers.get('if-none-match')).toBeNull();
  });

  // Without Age the browser measures the origin's stale-while-revalidate window from receipt
  // rather than from the response's real age, so the edge's staleness and the browser's compound
  // instead of sharing one clock — which is what makes a live counter appear to go backwards.
  it('forwards Age and cf-cache-status so edge staleness is visible to the browser', async () => {
    interceptFetch(
      'GET',
      `${ORIGIN}/widgets/plausible/pageviews/abc123`,
      () =>
        new Response('<span>Viewed 48 times</span>', {
          headers: {
            'content-type': 'text/html',
            'cache-control': 'public, max-age=0, stale-while-revalidate=300',
            age: '2400',
            'cf-cache-status': 'HIT',
          },
        })
    );

    const res = await handleApi(
      new Request('https://www.example.com/widgets/plausible/pageviews/abc123'),
      env
    );

    expect(res.status).toBe(200);
    expect(res.headers.get('age')).toBe('2400');
    expect(res.headers.get('cf-cache-status')).toBe('HIT');
  });

  it('forwards Age on a 304 so the revalidation updates the stored age', async () => {
    interceptFetch(
      'GET',
      `${ORIGIN}/widgets/whoop`,
      () =>
        new Response('<div>whoop</div>', {
          headers: { etag: 'W/"abc123"', age: '120' },
        })
    );

    const res = await handleApi(
      new Request('https://www.example.com/widgets/whoop', {
        headers: { 'if-none-match': 'W/"abc123"' },
      }),
      env
    );

    expect(res.status).toBe(304);
    expect(res.headers.get('age')).toBe('120');
  });

  it('omits Age entirely when the origin response was not cached', async () => {
    interceptFetch(
      'GET',
      `${ORIGIN}/widgets/whoop`,
      () => new Response('<div>whoop</div>', { headers: { etag: 'W/"x"' } })
    );

    const res = await handleApi(
      new Request('https://www.example.com/widgets/whoop'),
      env
    );

    expect(res.headers.get('age')).toBeNull();
    expect(res.headers.get('cf-cache-status')).toBeNull();
  });

  it('returns the full 200 with the new ETag when the validator does not match', async () => {
    interceptFetch(
      'GET',
      `${ORIGIN}/widgets/whoop`,
      () => new Response('<div>whoop</div>', { headers: { etag: 'W/"new"' } })
    );

    const res = await handleApi(
      new Request('https://www.example.com/widgets/whoop', {
        headers: { 'if-none-match': 'W/"old"' },
      }),
      env
    );

    expect(res.status).toBe(200);
    expect(res.headers.get('etag')).toBe('W/"new"');
    expect(await res.text()).toBe('<div>whoop</div>');
  });

  // HEAD is in ALLOWED_METHODS and takes the no-body branch upstream, but every other test here
  // drives GET or POST.
  it('proxies a HEAD as a HEAD, with no request body', async () => {
    const upstream = interceptFetch(
      'HEAD',
      `${ORIGIN}/widgets/whoop`,
      () =>
        new Response(null, {
          headers: { 'content-type': 'text/html', etag: 'W/"x"' },
        })
    );

    const res = await handleApi(
      new Request('https://www.example.com/widgets/whoop', { method: 'HEAD' }),
      env
    );

    expect(res.status).toBe(200);
    expect(upstream.calls).toBe(1);
    expect(upstream.request?.method).toBe('HEAD');
    expect(upstream.body).toBe('');
    expect(res.headers.get('etag')).toBe('W/"x"');
  });

  it('405s a method the route does not accept, without touching the origin', async () => {
    // No intercept registered at all: reaching the origin would throw an unmocked-fetch error.
    const res = await handleApi(
      new Request('https://www.example.com/widgets/whoop', { method: 'PUT' }),
      env
    );
    expect(res.status).toBe(405);
    expect(res.headers.get('allow')).toBe('GET, HEAD');
    expect(await res.text()).toBe('');
  });

  it('405s a GET to the contact path (POST only)', async () => {
    const res = await handleApi(
      new Request('https://www.example.com/api/contact'),
      env
    );
    expect(res.status).toBe(405);
    expect(res.headers.get('allow')).toBe('POST');
  });

  it('returns an empty 502 when the origin fetch fails', async () => {
    interceptFetch('GET', `${ORIGIN}/widgets/boom`, () => {
      throw new Error('connect ECONNREFUSED');
    });

    const res = await handleApi(
      new Request('https://www.example.com/widgets/boom'),
      env
    );
    expect(res.status).toBe(502);
    expect(await res.text()).toBe('');
    expect(res.headers.get('cache-control')).toBe('public, max-age=10');
    expect(res.headers.get('x-content-type-options')).toBe('nosniff');
    expect(res.headers.get('x-frame-options')).toBe('DENY');
  });

  it('degrades to the empty 502 when KONA_API_URL is unset instead of throwing', async () => {
    // A deploy can strip the dashboard var (see the keep_vars note in wrangler.jsonc). That must
    // collapse the widget, not surface Cloudflare's 1101 error page.
    const res = await handleApi(
      new Request('https://www.example.com/widgets/whoop'),
      { API_TOKEN: 'SERVER_TOKEN' } as Env
    );
    expect(res.status).toBe(502);
    expect(await res.text()).toBe('');
  });
});

describe('handleApi — contact (POST)', () => {
  it('forwards the visitor IP/UA/geo and the redirect Location, plus the bearer', async () => {
    const upstream = interceptFetch(
      'POST',
      `${ORIGIN}/api/contact`,
      () =>
        new Response('', {
          status: 303,
          headers: { location: 'https://www.example.com/contact/success' },
        })
    );

    const res = await handleApi(
      new Request('https://www.example.com/api/contact', {
        method: 'POST',
        headers: {
          'content-type': 'application/x-www-form-urlencoded',
          'cf-connecting-ip': '203.0.113.7',
          'user-agent': 'TestBrowser/1.0',
          accept: 'text/html',
        },
        body: 'name=T&email=t@example.com&message=hi',
        // request.cf on an inbound Worker request; the pool honours the RequestInit extension.
        cf: { city: 'Portland', region: 'Oregon', country: 'US' },
      } as RequestInit),
      env
    );

    // The no-JS 303 Location is forwarded back to the browser.
    expect(res.status).toBe(303);
    expect(res.headers.get('location')).toBe(
      'https://www.example.com/contact/success'
    );

    // The origin gets the real visitor signal it can't otherwise see, under X-Kona-Client-*.
    const sent = upstream.request!.headers;
    expect(sent.get('x-kona-client-ip')).toBe('203.0.113.7');
    expect(sent.get('x-kona-client-ua')).toBe('TestBrowser/1.0');
    expect(sent.get('x-kona-client-city')).toBe('Portland');
    expect(sent.get('x-kona-client-region')).toBe('Oregon');
    expect(sent.get('x-kona-client-country')).toBe('US');
    expect(sent.get('authorization')).toBe('Bearer SERVER_TOKEN');
    expect(sent.get('content-type')).toContain(
      'application/x-www-form-urlencoded'
    );
    // Contact is the one route that needs accept — it picks the JSON 204/422 vs. the no-JS 303.
    expect(sent.get('accept')).toBe('text/html');
    // The streamed body still arrives intact.
    expect(upstream.body).toBe('name=T&email=t@example.com&message=hi');
  });

  // The timeout used to sit inside the non-contact branch alongside cacheEverything, so the one
  // route a visitor actually waits on was the one with no bound at all.
  it('bounds the upstream request with a timeout', async () => {
    const upstream = interceptFetch(
      'POST',
      `${ORIGIN}/api/contact`,
      () => new Response(null, { status: 204 })
    );

    await handleApi(
      new Request('https://www.example.com/api/contact', {
        method: 'POST',
        headers: { accept: 'application/json' },
        body: 'name=T',
      }),
      env
    );

    expect(upstream.request!.signal).toBeTruthy();
    expect(upstream.request!.signal.aborted).toBe(false);
  });
});
