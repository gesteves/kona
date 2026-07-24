import { describe, it, expect } from 'vitest';
import { handleFeed } from '../src/feed-source';
import { assetsReturning, feedResponse, FEED_XML } from './helpers';

const feedRequest = (userAgent?: string): Request =>
  new Request('https://www.example.com/feed.xml', {
    headers: userAgent ? { 'user-agent': userAgent } : {},
  });

const envServing = (response: () => Response): Env =>
  ({ ASSETS: assetsReturning(response) }) as Env;

describe('handleFeed', () => {
  it('relabels utm_source to the reader name for a known feed reader', async () => {
    const res = await handleFeed(
      feedRequest('Feedly/1.0 (+https://feedly.com)'),
      envServing(feedResponse)
    );
    const body = await res.text();

    // Both build-baked permalinks are relabelled, campaign preserved.
    expect(body).toContain('utm_source=Feedly&amp;utm_medium=feed');
    expect(body).toContain(
      'utm_source=Feedly&amp;utm_medium=feed&amp;utm_campaign=running'
    );
    // The build-time anchor is gone…
    expect(body).not.toContain('utm_source=Feed&amp;');
    // …but an unrelated in-content utm_source is untouched.
    expect(body).toContain('utm_source=newsletter');
  });

  it('strips the whole utm cluster for a known crawler (non-reader)', async () => {
    const res = await handleFeed(
      feedRequest('Mozilla/5.0 (compatible; Googlebot/2.1)'),
      envServing(feedResponse)
    );
    const body = await res.text();

    // The feed's own attribution is removed entirely, leaving bare permalinks.
    expect(body).not.toContain('utm_source=Feed');
    expect(body).not.toContain('utm_medium=feed');
    expect(body).not.toContain('utm_campaign=running');
    expect(body).toContain('href="https://www.example.com/2026/06/26/post/"');
    // In-content utm params are not the feed anchor, so they survive.
    expect(body).toContain('utm_source=newsletter');
  });

  it('leaves the build-time Feed source untouched for an unknown agent', async () => {
    const res = await handleFeed(
      feedRequest('curl/8.4.0'),
      envServing(feedResponse)
    );
    const body = await res.text();
    expect(body).toBe(FEED_XML);
  });

  it('leaves the body untouched when there is no User-Agent', async () => {
    const res = await handleFeed(feedRequest(), envServing(feedResponse));
    expect(await res.text()).toBe(FEED_XML);
  });

  it('always sets a private, non-shared-cacheable Cache-Control', async () => {
    for (const ua of ['Feedly', 'Googlebot', 'curl/8']) {
      const res = await handleFeed(feedRequest(ua), envServing(feedResponse));
      expect(res.headers.get('cache-control')).toBe(
        'private, max-age=0, must-revalidate'
      );
      expect(res.headers.get('vary')).toBe('user-agent');
    }
  });

  it('passes a 304 (no body) straight through without rewriting', async () => {
    const res = await handleFeed(
      feedRequest('Feedly'),
      envServing(() => new Response(null, { status: 304 }))
    );
    expect(res.status).toBe(304);
    expect(await res.text()).toBe('');
  });

  it('passes a non-XML response through untouched', async () => {
    const res = await handleFeed(
      feedRequest('Feedly'),
      envServing(
        () =>
          new Response('<html>not a feed</html>', {
            status: 200,
            headers: { 'content-type': 'text/html' },
          })
      )
    );
    expect(await res.text()).toBe('<html>not a feed</html>');
  });

  it('serves the unmodified feed if the rewrite throws', async () => {
    // First ASSETS.fetch (inside rewriteFeed) throws; the catch re-fetches clean. Alternate the
    // stub so the retry succeeds.
    let call = 0;
    const env = {
      ASSETS: {
        fetch: async () => {
          call += 1;
          if (call === 1) throw new Error('boom');
          return feedResponse();
        },
      },
    } as unknown as Env;

    const res = await handleFeed(feedRequest('Feedly'), env);
    expect(res.status).toBe(200);
    // Served clean (unrelabelled) from the retry path.
    expect(await res.text()).toBe(FEED_XML);
  });
});
