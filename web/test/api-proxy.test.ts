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
    // The Cache-Control for the browser goes through with no change.
    expect(res.headers.get('cache-control')).toBe(
      'public, max-age=0, stale-while-revalidate=300'
    );
    // The edge policy never goes to the browser.
    expect(res.headers.get('cdn-cache-control')).toBeNull();
    expect(await res.text()).toBe('<div>weather</div>');

    // The upstream request: the server adds its bearer token, it removes the token of the client,
    // and it removes the cookie.
    const sent = upstream.request!.headers;
    expect(sent.get('authorization')).toBe('Bearer SERVER_TOKEN');
    expect(sent.get('cookie')).toBeNull();
    // accept goes on the contact path only. It is different for each browser and the edge cache
    // key ignores it. Thus it would break the rule that the upstream request of each viewer is the
    // same.
    expect(sent.get('accept')).toBeNull();
    // A widget never sends the visitor data. That data goes on the contact path only.
    expect(sent.get('x-kona-client-ip')).toBeNull();
    // The code makes each fragment response here, thus each one has its own security headers.
    expect(res.headers.get('x-content-type-options')).toBe('nosniff');
    expect(res.headers.get('x-frame-options')).toBe('DENY');
  });

  it('strips the query string so a junk param cannot bust the path-keyed edge cache', async () => {
    // The intercept covers the path with no query, and an intercept matches the full URL, with the
    // query. Thus an upstream request with a query matches nothing and raises, and this test fails
    // with an unmocked-fetch error and does not pass with no message.
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

  // ⚠️ This request has the API_TOKEN that the code adds. Thus the path must never decide the
  // upstream ORIGIN. `new URL(path, base)` would change a path with no protocol into a different
  // host and would send the bearer token there. An assignment of `pathname` on the base cannot.
  it('keeps a protocol-relative path on the configured origin', async () => {
    const upstream = interceptFetch(
      'GET',
      `${ORIGIN}//evil.example/widgets/whoop`,
      () => new Response('<div>whoop</div>')
    );

    const res = await handleApi(
      new Request('https://www.example.com//evil.example/widgets/whoop'),
      env
    );

    expect(res.status).toBe(200);
    expect(new URL(upstream.request!.url).origin).toBe(new URL(ORIGIN).origin);
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
    // The proxy answers the conditional request, and it never sends it upstream. An If-None-Match
    // for each client on the upstream request would break the one shared edge cache entry.
    expect(upstream.request!.headers.get('if-none-match')).toBeNull();
  });

  // Without Age, the browser measures the stale-while-revalidate window of the origin from the
  // time that it gets the response, and not from the true age of that response. Thus the age at the
  // edge and the age in the browser add together, and they do not use one clock. That is what makes
  // a live counter look like it goes down.
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

  // HEAD is in ALLOWED_METHODS and it goes upstream with no body, but each other test here uses
  // GET or POST.
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
    // There is no intercept. A request to the origin would raise an unmocked-fetch error.
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
    // A deploy can remove the variable from the dashboard (refer to the keep_vars note in
    // wrangler.jsonc). That must remove the widget, and it must not show the Cloudflare 1101 error
    // page.
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
        // request.cf on a Worker request that comes in. The pool obeys the RequestInit
        // extension.
        cf: { city: 'Portland', region: 'Oregon', country: 'US' },
      } as RequestInit),
      env
    );

    // The Location of the 303 for the path with no JavaScript goes back to the browser.
    expect(res.status).toBe(303);
    expect(res.headers.get('location')).toBe(
      'https://www.example.com/contact/success'
    );

    // The origin gets the true visitor data, which it cannot see in another way, in the
    // X-Kona-Client-* headers.
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
    // The contact route is the one route that needs accept: it selects between the JSON 204 or 422
    // and the 303 for a browser with no JavaScript.
    expect(sent.get('accept')).toBe('text/html');
    // The body from the stream arrives with no change.
    expect(upstream.body).toBe('name=T&email=t@example.com&message=hi');
  });

  // The timeout was in the branch for the routes that are not the contact route, with
  // cacheEverything. Thus the one route that a visitor waits for was the one route with no
  // limit.
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
