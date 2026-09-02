import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { handleOg, readOgTitle } from '../src/og';
import { makeCtx, assetsReturning, assetsRecording } from './helpers';

// ⚠️ This suite never imports ../src/og-render, on purpose, and nothing that it loads imports that
// module. That module imports the card font and the logo as Data modules, and the fallback module
// loader of the vitest pool sets the type only for `.wasm`. It reads each other file as UTF-8 and
// parses it as JS. Thus a `.ttf` import there gives a syntax error that does not show its cause.
// The `render` parameter on handleOg is what keeps that module out. Refer to web/CLAUDE.md.
// `wrangler dev` covers the render itself.

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47]) as Uint8Array<ArrayBuffer>;
const renderStub = () => vi.fn(async () => PNG);

const page = (body: string) =>
  new Response(body, { status: 200, headers: { 'content-type': 'text/html' } });

const withTitle = (title: string) =>
  page(
    `<html><head><meta property="og:title" content="${title}"></head></html>`
  );

// A page that names this card as its og:image, with the `v` that the build wrote.
const withCard = (title: string, cardPath = '/post/', v = 'v1-9') =>
  page(
    `<html><head><meta property="og:title" content="${title}"><meta property="og:image" content="https://www.example.com${cardPath}og.png?v=${v}"></head></html>`
  );

const envWith = (response: () => Response) =>
  ({ ASSETS: assetsReturning(response) }) as unknown as Env;

// The path of the page gives the path of its card: the card for /post/ is /post/og.png, and the
// card for the home page is /og.png. `v` is the only parameter.
const request = (path: string, init?: RequestInit) =>
  new Request(`https://www.example.com${path}`, init);

describe('handleOg', () => {
  // The handler reads caches.default and writes to it. Replace both, thus a test never uses the
  // true Cache storage, which the pool keeps separate for each test. Without this, the write
  // causes the same miniflare storage teardown problem that the plausible suite and the index
  // suite also prevent. `match` gives a miss, which makes the code render. `put` does nothing.
  beforeEach(() => {
    vi.spyOn(caches.default, 'match').mockResolvedValue(undefined);
    vi.spyOn(caches.default, 'put').mockResolvedValue(undefined);
  });
  afterEach(() => vi.restoreAllMocks());

  describe('request validation', () => {
    it('405s a POST before touching the assets or the renderer', async () => {
      const render = renderStub();
      const res = await handleOg(
        request('/og.png', { method: 'POST' }),
        {} as Env,
        makeCtx(),
        render
      );
      expect(res.status).toBe(405);
      expect(res.headers.get('allow')).toBe('GET, HEAD');
      expect(render).not.toHaveBeenCalled();
    });

    // This is a safety check only. The router and the run_worker_first globs both use the suffix,
    // thus this code runs only when the two do not agree.
    it('400s a path that is not a card path', async () => {
      const res = await handleOg(
        request('/post/?v=v1'),
        {} as Env,
        makeCtx(),
        renderStub()
      );
      expect(res.status).toBe(400);
    });

    // The body of each response that is not an image is only its status line. There is no message
    // that names the step that failed, because this endpoint is public and nothing reads the
    // body.
    it.each([
      [400, '400 Bad Request', '/post/?v=v1', 'GET'],
      [405, '405 Method Not Allowed', '/og.png', 'POST'],
    ])('answers %i with "%s"', async (status, body, path, method) => {
      const res = await handleOg(
        request(path, { method }),
        {} as Env,
        makeCtx(),
        renderStub()
      );
      expect(res.status).toBe(status);
      expect(await res.text()).toBe(body);
      expect(res.headers.get('cache-control')).toBe('public, max-age=300');
    });
  });

  describe('title lookup through the ASSETS binding', () => {
    // The path of the card names the page: remove the file name from the end, and the code looks
    // up the remainder. A path of /og.png alone is the card of the home page. ⚠️ The slash at the
    // end must stay. The asset from the build is /post/index.html, and auto-trailing-slash answers
    // a /post with no slash with a redirect. The check for a 200 below would make that a 404.
    it.each([
      ['/2026/06/26/post/og.png?v=v1-9#frag', '/2026/06/26/post/'],
      ['/og.png?v=v1', '/'],
      // ⚠️ A path that looks like it has no protocol must stay on this origin. The lookup sets
      // `pathname` and does not resolve the path against the URL that comes in, thus it stays.
      ['//evil.example/og.png?v=v1', '//evil.example/'],
    ])(
      'asks the asset layer for %s on the incoming origin',
      async (path, expected) => {
        const assets = assetsRecording(() => withTitle('Hello'));
        await handleOg(
          request(path),
          { ASSETS: assets.binding } as unknown as Env,
          makeCtx(),
          renderStub()
        );
        expect(assets.requests).toHaveLength(1);
        expect(assets.requests[0].url).toBe(
          `https://www.example.com${expected}`
        );
      }
    );

    it('strips the query and fragment before the asset lookup', async () => {
      const assets = assetsRecording(() => withTitle('Hello'));
      await handleOg(
        request('/post/og.png?v=v1&a=b#frag'),
        { ASSETS: assets.binding } as unknown as Env,
        makeCtx(),
        renderStub()
      );
      expect(assets.requests[0].url).toBe('https://www.example.com/post/');
    });

    // With not_found_handling: "404-page", a miss returns the markup of the 404 page from the
    // build, and that page has an og:title of its own. Thus the status, and not the body, is what
    // removes it.
    it('404s when the asset layer does not return a clean 200', async () => {
      const render = renderStub();
      const res = await handleOg(
        request('/nope/og.png?v=v1'),
        envWith(
          () =>
            new Response('<meta property="og:title" content="Not found">', {
              status: 404,
              headers: { 'content-type': 'text/html' },
            })
        ),
        makeCtx(),
        render
      );
      expect(res.status).toBe(404);
      expect(render).not.toHaveBeenCalled();
    });

    it('404s a 200 that is not HTML, rather than reading it as text', async () => {
      const render = renderStub();
      const res = await handleOg(
        request('/thing.pdf/og.png?v=v1'),
        envWith(
          () =>
            new Response('%PDF-1.4', {
              status: 200,
              headers: { 'content-type': 'application/pdf' },
            })
        ),
        makeCtx(),
        render
      );
      expect(res.status).toBe(404);
      expect(render).not.toHaveBeenCalled();
    });

    it('404s a page that carries no og:title', async () => {
      const res = await handleOg(
        request('/post/og.png?v=v1'),
        envWith(() => page('<html><head><title>Bare</title></head></html>')),
        makeCtx(),
        renderStub()
      );
      expect(res.status).toBe(404);
      expect(await res.text()).toBe('404 Not Found');
    });

    // ⚠️ A page decides its own card. A page with a cover image names that image, and a page
    // with no og:image names nothing. Neither one has a card to render.
    it.each([
      ['no og:image', withTitle('Hello')],
      [
        'a cover image as its og:image',
        page(
          '<meta property="og:title" content="Hello"><meta property="og:image" content="https://images.example.com/cdn-cgi/image/w=1200/x.jpg">'
        ),
      ],
      ['the card of another page', withCard('Hello', '/other/', 'v1')],
    ])('404s a page with %s, without rendering', async (_label, response) => {
      const render = renderStub();
      const res = await handleOg(
        request('/post/og.png?v=v1'),
        envWith(() => response),
        makeCtx(),
        render
      );
      expect(res.status).toBe(404);
      expect(render).not.toHaveBeenCalled();
    });

    it('renders the page’s own og:title, entity-decoded', async () => {
      const render = renderStub();
      await handleOg(
        request('/post/og.png?v=v1'),
        envWith(() => withCard('Salt &amp; Vinegar', '/post/', 'v1')),
        makeCtx(),
        render
      );
      expect(render).toHaveBeenCalledWith('Salt & Vinegar');
    });
  });

  describe('the rendered response', () => {
    const ok = () =>
      handleOg(
        request('/post/og.png?v=v1-9'),
        envWith(() => withCard('Hello')),
        makeCtx(),
        renderStub()
      );

    it('serves the PNG with an immutable year', async () => {
      const res = await ok();
      expect(res.status).toBe(200);
      expect(res.headers.get('content-type')).toBe('image/png');
      expect(res.headers.get('cache-control')).toBe(
        'public, max-age=31536000, immutable'
      );
      expect(res.headers.get('x-content-type-options')).toBe('nosniff');
      expect(new Uint8Array(await res.arrayBuffer())).toEqual(PNG);
    });

    it('answers a HEAD with the same headers and no body', async () => {
      const res = await handleOg(
        request('/post/og.png?v=v1-9', { method: 'HEAD' }),
        envWith(() => withCard('Hello')),
        makeCtx(),
        renderStub()
      );
      expect(res.status).toBe(200);
      expect(res.headers.get('content-type')).toBe('image/png');
      expect(await res.arrayBuffer()).toHaveProperty('byteLength', 0);
    });

    it('500s and does not cache when the render throws', async () => {
      const render = vi.fn(async () => {
        throw new Error('boom');
      });
      const res = await handleOg(
        request('/post/og.png?v=v1'),
        envWith(() => withCard('Hello', '/post/', 'v1')),
        makeCtx(),
        render as unknown as () => Promise<Uint8Array<ArrayBuffer>>
      );
      expect(res.status).toBe(500);
      expect(await res.text()).toBe('500 Internal Server Error');
      expect(res.headers.get('cache-control')).toBe('public, max-age=300');
      expect(caches.default.put).not.toHaveBeenCalled();
    });
  });

  describe('caching', () => {
    it('keys on the card path and v only, dropping unknown params', async () => {
      await handleOg(
        request('/post/og.png?v=v1-9&utm_source=slack&x=random'),
        envWith(() => withCard('Hello')),
        makeCtx(),
        renderStub()
      );

      // ⚠️ `v` must go into the key. It is what makes the content address the card, thus without
      // it the code would serve the old PNG of a page that a user published again, for all time. A
      // bad parameter must not go into the key: with it, ?x=<random> makes an unlimited number of
      // entries, and each one is a miss that costs a full render.
      const [matched] = vi.mocked(caches.default.match).mock.calls[0];
      const [stored] = vi.mocked(caches.default.put).mock.calls[0];
      const expected = 'https://www.example.com/post/og.png?v=v1-9';
      expect((matched as Request).url).toBe(expected);
      expect((stored as Request).url).toBe(expected);
    });

    // ⚠️ The caller supplies `v`, thus an attacker can write a cache key. Each different value is
    // a miss, and a miss must not cost a full satori and resvg render. Thus a value that is not the
    // one the page declares goes to the declared one, and only that one renders. A value with no
    // known shape reads the cache under one key first, thus junk cannot make many entries.
    it.each([
      ['?v=' + 'a'.repeat(200), 'a long junk value', ''],
      ['?v=v1-9-extra', 'a value that only looks like a version', ''],
      ['?v=../../etc', 'a traversal-shaped value', ''],
      ['', 'no v at all', ''],
      ['?v=v1-8', 'an old version', 'v1-8'],
      ['?v=v1-99999', 'a version that looks real', 'v1-99999'],
    ])(
      'redirects %s (%s) to the version the page declares, without rendering',
      async (query, _label, key) => {
        const render = renderStub();
        const res = await handleOg(
          request(`/post/og.png${query}`),
          envWith(() => withCard('Hello')),
          makeCtx(),
          render
        );

        const [matched] = vi.mocked(caches.default.match).mock.calls[0];
        expect((matched as Request).url).toBe(
          `https://www.example.com/post/og.png?v=${key}`
        );
        expect(res.status).toBe(301);
        expect(res.headers.get('location')).toBe(
          'https://www.example.com/post/og.png?v=v1-9'
        );
        expect(res.headers.get('cache-control')).toBe('public, max-age=300');
        expect(render).not.toHaveBeenCalled();
        expect(caches.default.put).not.toHaveBeenCalled();
      }
    );

    it.each(['v1', 'v1-9', 'v12-345'])(
      'renders and keys a version that the page declares (%s)',
      async (v) => {
        const render = renderStub();
        await handleOg(
          request(`/post/og.png?v=${v}`),
          envWith(() => withCard('Hello', '/post/', v)),
          makeCtx(),
          render
        );

        const [matched] = vi.mocked(caches.default.match).mock.calls[0];
        const [stored] = vi.mocked(caches.default.put).mock.calls[0];
        expect((matched as Request).url).toBe(
          `https://www.example.com/post/og.png?v=${v}`
        );
        expect((stored as Request).url).toBe(
          `https://www.example.com/post/og.png?v=${v}`
        );
        expect(render).toHaveBeenCalledOnce();
      }
    );

    it('renders the card of the home page, whose og:image has no page path', async () => {
      const render = renderStub();
      const res = await handleOg(
        request('/og.png?v=v2'),
        envWith(() => withCard('Home', '/', 'v2')),
        makeCtx(),
        render
      );
      expect(res.status).toBe(200);
      expect(render).toHaveBeenCalledWith('Home');
    });

    it('serves a cache hit without rendering', async () => {
      vi.mocked(caches.default.match).mockResolvedValue(
        new Response(PNG, { headers: { 'content-type': 'image/png' } })
      );
      const render = renderStub();
      const res = await handleOg(
        request('/post/og.png?v=v1-9'),
        envWith(() => withCard('Hello')),
        makeCtx(),
        render
      );
      expect(res.status).toBe(200);
      expect(new Uint8Array(await res.arrayBuffer())).toEqual(PNG);
      expect(render).not.toHaveBeenCalled();
    });
  });
});

describe('readOgTitle', () => {
  const page = (html: string) =>
    new Response(html, { headers: { 'content-type': 'text/html' } });

  it('reads the content attribute with either quote style', async () => {
    await expect(
      readOgTitle(page('<meta property="og:title" content="Double">'))
    ).resolves.toBe('Double');
    await expect(
      readOgTitle(page("<meta property='og:title' content='Single'>"))
    ).resolves.toBe('Single');
  });

  it('ignores other meta tags', async () => {
    await expect(
      readOgTitle(
        page(
          '<meta name="description" content="Nope"><meta property="og:title" content="Yes">'
        )
      )
    ).resolves.toBe('Yes');
  });

  it('takes the first og:title when a page carries more than one', async () => {
    await expect(
      readOgTitle(
        page(
          '<meta property="og:title" content="First"><meta property="og:title" content="Second">'
        )
      )
    ).resolves.toBe('First');
  });

  it('returns null when there is no og:title', async () => {
    await expect(
      readOgTitle(page('<html><title>Bare</title></html>'))
    ).resolves.toBeNull();
  });

  // The code adds the body to the stream but never closes it. Thus this can resolve only if the
  // read stops at the tag and does not go to the end. That is the purpose on a route that is near
  // the CPU limit. HTMLRewriter decides if the cancel reaches the source stream, thus this file
  // does not test that.
  it('stops reading once the tag is found instead of draining the body', async () => {
    const body = new ReadableStream({
      start(controller) {
        controller.enqueue(
          new TextEncoder().encode(
            '<head><meta property="og:title" content="Early"></head>'
          )
        );
      },
    });

    await expect(
      readOgTitle(
        new Response(body, { headers: { 'content-type': 'text/html' } })
      )
    ).resolves.toBe('Early');
  });

  // ⚠️ The getAttribute of HTMLRewriter returns the attribute as the source writes it, with the
  // entities. Thus decodeEntities still runs on the result.
  it.each([
    ['&amp;', '&'],
    ['&lt;tag&gt;', '<tag>'],
    ['&quot;quoted&quot;', '"quoted"'],
    ['&#39;', "'"],
    ['&#x27;', "'"],
    ['&apos;', "'"],
    ['&#8217;', '\u2019'],
    ['&#x2019;', '\u2019'],
  ])('decodes %s in the title', async (input, expected) => {
    await expect(
      readOgTitle(page(`<meta property="og:title" content="${input}">`))
    ).resolves.toBe(expected);
  });

  // ⚠️ String.fromCodePoint raises RangeError above 0x10FFFF, and this code runs on a path that
  // handleOg does not catch. Thus one bad entity in a published og:title made the card give a 500.
  // The code keeps the entity as the source writes it and does not remove it. Thus the result is
  // an entity that you can see, and not a gap with no message.
  it.each([
    ['&#1114112;', '&#1114112;'],
    ['&#x110000;', '&#x110000;'],
    ['&#99999999999;', '&#99999999999;'],
  ])(
    'passes the out-of-range entity %s through instead of throwing',
    async (input, expected) => {
      await expect(
        readOgTitle(page(`<meta property="og:title" content="Title ${input}">`))
      ).resolves.toBe(`Title ${expected}`);
    }
  );

  // ⚠️ `&amp;` is the escape for the ampersand that starts each other entity. Thus a decoder that
  // ran two times would make this into a "<" character.
  it('does not double-decode an escaped entity', async () => {
    await expect(
      readOgTitle(page('<meta property="og:title" content="&amp;lt;">'))
    ).resolves.toBe('&lt;');
  });
});
