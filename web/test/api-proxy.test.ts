import { describe, it, expect } from 'vitest';
import { fetchMock } from 'cloudflare:test';
import { handleApi } from '../src/api-proxy';

const ORIGIN = 'https://origin.test';
const env = { KONA_API_URL: ORIGIN, API_TOKEN: 'SERVER_TOKEN' } as Env;

// undici's reply callback hands us the upstream request it received. Normalize header access
// (fetch lowercases names) so tests can assert what the Worker actually sent to the origin.
type Captured = {
  headers: Record<string, string | string[]>;
  body?: string | null;
};
const header = (c: Captured, name: string): string | undefined => {
  const v = c.headers[name.toLowerCase()];
  return Array.isArray(v) ? v[0] : v;
};

describe('handleApi — widgets (GET)', () => {
  it('injects the constant bearer, drops the client authorization and accept', async () => {
    let captured!: Captured;
    fetchMock
      .get(ORIGIN)
      .intercept({ path: '/widgets/weather/current', method: 'GET' })
      .reply((opts) => {
        captured = opts as unknown as Captured;
        return {
          statusCode: 200,
          data: '<div>weather</div>',
          responseOptions: {
            headers: {
              'content-type': 'text/html',
              'cache-control': 'public, max-age=0, stale-while-revalidate=300',
              'cdn-cache-control': 'public, max-age=300',
            },
          },
        };
      });

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
    expect(header(captured, 'authorization')).toBe('Bearer SERVER_TOKEN');
    expect(header(captured, 'cookie')).toBeUndefined();
    // accept is contact-only: it varies per browser and the edge cache key ignores it, so
    // forwarding it would break the "every viewer's upstream request is identical" invariant.
    expect(header(captured, 'accept')).toBeUndefined();
    // Widgets never forward the visitor signal — that's contact-only.
    expect(header(captured, 'x-kona-client-ip')).toBeUndefined();
    // Fragments are built from scratch here, so they carry their own security headers.
    expect(res.headers.get('x-content-type-options')).toBe('nosniff');
    expect(res.headers.get('x-frame-options')).toBe('DENY');
  });

  it('strips the query string so a junk param cannot bust the path-keyed edge cache', async () => {
    // Only the BARE path is intercepted. undici throws on an unmatched request, so if the query
    // ever reached the origin this test fails with an unmatched-intercept error rather than
    // silently passing.
    let captured!: Captured;
    fetchMock
      .get(ORIGIN)
      .intercept({ path: '/widgets/whoop', method: 'GET' })
      .reply((opts) => {
        captured = opts as unknown as Captured;
        return { statusCode: 200, data: '<div>whoop</div>' };
      });

    const res = await handleApi(
      new Request('https://www.example.com/widgets/whoop?bust=random'),
      env
    );

    expect(res.status).toBe(200);
    expect(await res.text()).toBe('<div>whoop</div>');
    // undici reports the path it actually received — no query on it.
    expect((captured as unknown as { path: string }).path).toBe(
      '/widgets/whoop'
    );
  });

  it('405s a method the route does not accept, without touching the origin', async () => {
    // No intercept registered at all: reaching the origin would throw an unmatched-request error.
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
    fetchMock
      .get(ORIGIN)
      .intercept({ path: '/widgets/boom', method: 'GET' })
      .replyWithError(new Error('connect ECONNREFUSED'));

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
    let captured!: Captured;
    fetchMock
      .get(ORIGIN)
      .intercept({ path: '/api/contact', method: 'POST' })
      .reply((opts) => {
        captured = opts as unknown as Captured;
        return {
          statusCode: 303,
          data: '',
          responseOptions: {
            headers: { location: 'https://www.example.com/contact/success' },
          },
        };
      });

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
    expect(header(captured, 'x-kona-client-ip')).toBe('203.0.113.7');
    expect(header(captured, 'x-kona-client-ua')).toBe('TestBrowser/1.0');
    expect(header(captured, 'x-kona-client-city')).toBe('Portland');
    expect(header(captured, 'x-kona-client-region')).toBe('Oregon');
    expect(header(captured, 'x-kona-client-country')).toBe('US');
    expect(header(captured, 'authorization')).toBe('Bearer SERVER_TOKEN');
    expect(header(captured, 'content-type')).toContain(
      'application/x-www-form-urlencoded'
    );
    // Contact is the one route that needs accept — it picks the JSON 204/422 vs. the no-JS 303.
    expect(header(captured, 'accept')).toBe('text/html');
    // The streamed body still arrives intact.
    expect(captured.body).toBe('name=T&email=t@example.com&message=hi');
  });
});
