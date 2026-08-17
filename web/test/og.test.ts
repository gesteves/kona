import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { handleOg, readOgTitle } from '../src/og';
import { makeCtx, assetsReturning, assetsRecording } from './helpers';

// ⚠️ This suite deliberately never imports ../src/og-render, and neither does anything it loads.
// That module imports the card font and logo as Data modules, and the vitest pool's module
// fallback loader force-types only `.wasm` — everything else is read as UTF-8 and parsed as JS,
// so a `.ttf` import there dies with a syntax error that looks nothing like its cause. The
// `render` parameter on handleOg is the seam that keeps it out; see web/CLAUDE.md.
// The render itself is covered by `wrangler dev` instead.

const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47]) as Uint8Array<ArrayBuffer>;
const renderStub = () => vi.fn(async () => PNG);

const page = (body: string) =>
  new Response(body, { status: 200, headers: { 'content-type': 'text/html' } });

const withTitle = (title: string) =>
  page(
    `<html><head><meta property="og:title" content="${title}"></head></html>`
  );

const envWith = (response: () => Response) =>
  ({ ASSETS: assetsReturning(response) }) as unknown as Env;

// Cards hang off the page's own path: the card for /post/ is /post/og.png, and the home page's
// is /og.png. `v` is the only parameter left.
const request = (path: string, init?: RequestInit) =>
  new Request(`https://www.example.com${path}`, init);

describe('handleOg', () => {
  // The handler reads and writes caches.default. Stub both so tests never touch real (per-test
  // isolated) Cache storage — that write otherwise trips the same miniflare isolated-storage
  // teardown bug the plausible and index suites work around. `match` → miss forces the render
  // path; `put` → no-op.
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

    // Defensive only: the router and the run_worker_first globs both key on the suffix, so this
    // is only reachable if the two have drifted apart.
    it('400s a path that is not a card path', async () => {
      const res = await handleOg(
        request('/post/?v=v1'),
        {} as Env,
        makeCtx(),
        renderStub()
      );
      expect(res.status).toBe(400);
    });

    // Every non-image response body is just its own status line — no bespoke message describing
    // which internal step failed, since this endpoint is public and nothing reads the body.
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
    // The card's own path names the page: chop the filename off the end and that's what gets
    // looked up. A bare /og.png is the home page's card. ⚠️ The trailing slash has to survive —
    // the built asset is /post/index.html, and auto-trailing-slash answers a slashless /post
    // with a redirect, which the 200-only check downstream would turn into a 404.
    it.each([
      ['/2026/06/26/post/og.png?v=v1-9#frag', '/2026/06/26/post/'],
      ['/og.png?v=v1', '/'],
      // ⚠️ Protocol-relative-looking paths must stay on this origin — the lookup assigns
      // `pathname` rather than resolving the path against the incoming URL, so they do.
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

    // not_found_handling: "404-page" means a miss returns the built 404 page's markup, which has
    // an og:title of its own — so the status, not the body, is what rules it out.
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

    it('renders the page’s own og:title, entity-decoded', async () => {
      const render = renderStub();
      await handleOg(
        request('/post/og.png?v=v1'),
        envWith(() => withTitle('Salt &amp; Vinegar')),
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
        envWith(() => withTitle('Hello')),
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
        envWith(() => withTitle('Hello')),
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
        envWith(() => withTitle('Hello')),
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
        envWith(() => withTitle('Hello')),
        makeCtx(),
        renderStub()
      );

      // ⚠️ `v` must survive into the key — it is what makes the card content-addressed, so
      // dropping it would serve a republished page's old PNG forever. Junk params must not, or
      // ?x=<random> mints an unbounded number of entries, each a miss costing a full render.
      const [matched] = vi.mocked(caches.default.match).mock.calls[0];
      const [stored] = vi.mocked(caches.default.put).mock.calls[0];
      const expected = 'https://www.example.com/post/og.png?v=v1-9';
      expect((matched as Request).url).toBe(expected);
      expect((stored as Request).url).toBe(expected);
    });

    // ⚠️ `v` is caller-supplied, so it is a cache key an attacker writes. Without normalisation
    // every distinct value is a miss costing a full satori + resvg render and a stored PNG —
    // dropping the *other* params is not enough on its own.
    it.each([
      ['?v=' + 'a'.repeat(200), 'a long junk value'],
      ['?v=v1-9-extra', 'a value that only looks like a version'],
      ['?v=../../etc', 'a traversal-shaped value'],
      ['', 'no v at all'],
    ])('collapses %s onto the unversioned key (%s)', async (query) => {
      await handleOg(
        request(`/post/og.png${query}`),
        envWith(() => withTitle('Hello')),
        makeCtx(),
        renderStub()
      );

      const [matched] = vi.mocked(caches.default.match).mock.calls[0];
      expect((matched as Request).url).toBe(
        'https://www.example.com/post/og.png?v='
      );
    });

    it.each(['v1', 'v1-9', 'v12-345'])(
      'keeps a real version (%s)',
      async (v) => {
        await handleOg(
          request(`/post/og.png?v=${v}`),
          envWith(() => withTitle('Hello')),
          makeCtx(),
          renderStub()
        );

        const [matched] = vi.mocked(caches.default.match).mock.calls[0];
        expect((matched as Request).url).toBe(
          `https://www.example.com/post/og.png?v=${v}`
        );
      }
    );

    it('serves a cache hit without rendering', async () => {
      vi.mocked(caches.default.match).mockResolvedValue(
        new Response(PNG, { headers: { 'content-type': 'image/png' } })
      );
      const render = renderStub();
      const res = await handleOg(
        request('/post/og.png?v=v1-9'),
        envWith(() => withTitle('Hello')),
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

  // The body is enqueued but never closed, so this can only resolve if the read stops at the tag
  // rather than draining to the end — which is the whole point on a route near the CPU budget.
  // (Whether the cancel propagates all the way to the source stream is HTMLRewriter's business,
  // so it isn't asserted here.)
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

  // ⚠️ HTMLRewriter's getAttribute returns the attribute exactly as written, entities included,
  // so decodeEntities still runs on the way out.
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

  // ⚠️ String.fromCodePoint throws RangeError above 0x10FFFF, and this runs on a path handleOg
  // does not wrap — so one bad entity in a published og:title used to 500 the card outright.
  // Left as written rather than dropped, so the damage is a visible entity, not a silent gap.
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

  // ⚠️ `&amp;` is the escape for the ampersand that introduces every other entity, so a decoder
  // that ran twice would turn this into a literal "<".
  it('does not double-decode an escaped entity', async () => {
    await expect(
      readOgTitle(page('<meta property="og:title" content="&amp;lt;">'))
    ).resolves.toBe('&lt;');
  });
});
