import type { Config, Context } from '@netlify/edge-functions';

// Rewrites the `utm_source` placeholder in the Atom feeds to name the feed reader that
// fetched them, so Plausible can break feed traffic down per reader instead of lumping it
// all into one opaque "Feed" source.
//
// The feeds are static files, so the reader is only knowable at request time from the User-
// Agent — hence an edge function. The build bakes in `utm_source=Feed&utm_medium=feed`
// (plus `utm_campaign=<tag>` on tag feeds; see UrlHelpers#feed_url in
// web/lib/helpers/url_helpers.rb) and this only ever substitutes the `utm_source` value.
// Everything else about the feed, including the tag, is decided at build time.
//
// Attribution notes, so the numbers are read correctly:
// - Cloud readers (Feedly, Feedbin, …) fetch once and serve N subscribers, so their UA is
//   the right label for every click that follows. On-device readers fetch per user.
// - This measures the *service*, not the app: Reeder, Fiery Feeds, Unread and ReadKit
//   usually sync via a Feedbin/Feedly/Inoreader backend, so the backend's UA is what
//   reaches us and the app is invisible. "Feedbin" means "read via Feedbin, in any app".

// The build-time placeholder value of utm_source, and the anchor this function substitutes.
// The feed markup is XML-escaped, so the raw bytes read `utm_source=Feed&amp;utm_medium=feed`.
// Anchoring on the trailing `&amp;` pins the match to a whole param value — it can't match a
// longer source like `utm_source=Feedburner` that happened to appear in entry content — and
// keeps the replacement from having to deal with the ampersand at all.
const SOURCE_ANCHOR = 'utm_source=Feed&amp;';

// Logged in place of the reader name when nothing matched. Grep the edge function logs for
// this to find feed readers worth adding to FEED_READERS below: the log line carries the
// full User-Agent next to it.
const UNMATCHED_LABEL = 'unmatched-reader';

// User agents of feed readers, mapped to the Source value they should get in Plausible.
// First match wins, so specific product tokens must come before anything broader.
//
// ⚠️ Match the product token only, never the version — Nextcloud News reports a vestigial
// `1.0`, Liferea's anonymous mode emits a *randomized* version, rss2email can be pinned to a
// stale one, and TT-RSS/CommaFeed can report `UNKNOWN`. ⚠️ Never add a bare /feed/ or /rss/
// pattern: either would shadow most of this list. And note `Mozilla/5.0` is a meaningless
// prefix (old Inoreader, BubblesBot and Miniflux all use it) — always match the inner token.
//
// Deliberately absent: page-unfurl bots (Discordbot, TelegramBot, Bluesky Cardyb,
// facebookexternalhit, Applebot) never fetch feeds, so they'd be dead patterns here — Slack
// is listed because it has a real feed-subscription product. Readers that can't be
// identified are also absent rather than guessed at: Stringer sends a bare `User-Agent:
// Ruby`, RSS-Bridge impersonates Firefox with no self-identifying code path, and PolitePol
// ships a Chrome 46 spoof. Several readers below (Miniflux, TT-RSS, FreshRSS, Newsboat,
// Liferea, Vienna, Akregator) also let users override the UA, so some traffic is disguised.
//
// A good reference when extending this: https://github.com/opawg/podcast-rss-useragents
const FEED_READERS: ReadonlyArray<readonly [RegExp, string]> = [
  // Cloud services — one fetch serves N subscribers.
  // Feedly must precede any FeedFetcher-Google pattern: its UA ends `; like FeedFetcher-Google)`.
  [/feedly/i, 'Feedly'],
  [/feedbin/i, 'Feedbin'],
  [/inoreader/i, 'Inoreader'],
  [/newsblur/i, 'NewsBlur'],
  [/bazqux/i, 'BazQux'],
  [/theoldreader/i, 'The Old Reader'],
  [/feed wrangler/i, 'Feed Wrangler'],
  [/newsify/i, 'Newsify'],
  [/feedspot/i, 'Feedspot'],
  [/blogtrottr/i, 'Blogtrottr'],
  [/superfeedr/i, 'Superfeedr'],
  [/netvibes/i, 'Netvibes'],
  [/newsnow\//i, 'NewsNow'],
  [/feeder\.co|spacecowboys/i, 'Feeder'],
  [/slackbot/i, 'Slack'],
  [/bubblesbot/i, 'Bubbles'],
  [/rss\.social/i, 'RSS.Social'],
  [/micro\.blog/i, 'Micro.blog'],
  [/flipboard/i, 'Flipboard'],
  [/dlvr\.it/i, 'dlvr.it'],
  [/zapier/i, 'Zapier'],
  [/granary/i, 'granary'],
  [/sismicsreaderbot/i, 'Sismics Reader'],

  // Self-hosted — server-side, but roughly one user each. Don't read as N subscribers.
  [/freshrss/i, 'FreshRSS'],
  [/miniflux/i, 'Miniflux'],
  [/tiny tiny rss|tt-rss/i, 'Tiny Tiny RSS'],
  [/nextcloud-news/i, 'Nextcloud News'],
  [/selfoss/i, 'Selfoss'],
  [/commafeed\//i, 'CommaFeed'],
  [/\byarr\//i, 'yarr'],
  [/rssowl\//i, 'RSSOwl'],

  // On-device — one fetch per user.
  [/netnewswire/i, 'NetNewsWire'],
  [/reeder\//i, 'Reeder'], // only in Reeder's local/iCloud mode; sync mode shows the backend
  [/unread rss/i, 'Unread'],
  [/vienna\//i, 'Vienna'],
  [/news explorer|betamagic/i, 'News Explorer'],
  [/emacs elfeed/i, 'Elfeed'],
  [/newsboat\//i, 'Newsboat'], // Newsbeuter differs only in case; it's dead, so it's omitted
  [/liferea/i, 'Liferea'],
  [/akregator\//i, 'Akregator'],
  [/thunderbird\//i, 'Thunderbird'],
  [/rss2email\//i, 'rss2email'],
  [/applesyndication/i, 'Safari RSS'],
];

function matchReader(userAgent: string | null): string | undefined {
  if (!userAgent) return undefined;
  return FEED_READERS.find(([pattern]) => pattern.test(userAgent))?.[1];
}

// The zone is proxied through Cloudflare, so the client that connects to Netlify is a
// Cloudflare edge node: context.ip / context.geo describe the PoP, not the visitor.
// Cloudflare passes the real ones through in CF-* request headers. Fall back to Netlify's
// own values when a request didn't come through Cloudflare (local dev, or a resolver still
// pointing straight at the origin).
function clientIp(request: Request, context: Context): string | undefined {
  return request.headers.get('CF-Connecting-IP') ?? context.ip;
}

// CF-IPCountry is a 2-letter code present on every proxied request; CF-IPCity and CF-Region
// ship together in the "Add visitor location headers" managed transform, so both are absent
// unless it's enabled on the zone — hence joining whatever is present rather than assuming a
// city or region. CF-Region is the spelled-out name ("Colorado"), not the CF-RegionCode
// short form. Netlify's own equivalent of the region is geo.subdivision.
function clientGeo(request: Request, context: Context): string | undefined {
  if (request.headers.get('CF-Connecting-IP')) {
    return (
      [
        request.headers.get('CF-IPCity'),
        request.headers.get('CF-Region'),
        request.headers.get('CF-IPCountry'),
      ]
        .filter(Boolean)
        .join(', ') || undefined
    );
  }
  return (
    [
      context.geo?.city,
      context.geo?.subdivision?.name,
      context.geo?.country?.name,
    ]
      .filter(Boolean)
      .join(', ') || undefined
  );
}

// CF-Ray is set only on requests that actually traversed Cloudflare, so its presence is the
// marker for "this came through the proxy". It's also the join key against the rayName field
// in Cloudflare's logs.
function cloudflareRay(request: Request): string | undefined {
  return request.headers.get('CF-Ray') ?? undefined;
}

// One pipe-separated request log line: the given lead-in parts, then the requester's
// referrer, user agent, IP, geo, and Cloudflare ray (when known). Mirrors the format of the
// widget proxy / OG functions' requestLogLine (web/netlify/functions/lib/log.mts) —
// reimplemented inline here, as known-agents.ts does, because that helper is a Node
// functions module and this runs in the Deno edge runtime.
function requestLogLine(
  request: Request,
  context: Context,
  ...parts: (string | null | undefined)[]
): string {
  return [
    ...parts,
    request.headers.get('Referer'),
    request.headers.get('User-Agent'),
    clientIp(request, context),
    clientGeo(request, context),
    cloudflareRay(request),
  ]
    .filter(Boolean)
    .join(' | ');
}

function isXml(response: Response): boolean {
  return response.headers.get('content-type')?.includes('xml') ?? false;
}

// A feed body varies per reader, so it must never be stored by a *shared* cache — one
// reader's copy served to another would attribute the clicks to the wrong source.
// `private` is the load-bearing guard: Cloudflare (which fronts this zone) ignores
// `Vary: User-Agent` entirely, so Vary alone would not protect us; it's here for caches that
// do honour it. `max-age=0, must-revalidate` still lets the reader itself keep a copy and
// revalidate with If-None-Match, so conditional GETs and 304s keep working — no bandwidth
// regression. Netlify-CDN-Cache-Control is deliberately never set: the mutated body must not
// be durably edge-cached either.
function withCacheGuards(headers: Headers): Headers {
  headers.set('cache-control', 'private, max-age=0, must-revalidate');
  headers.set('vary', 'user-agent');
  return headers;
}

export default async function handler(
  request: Request,
  context: Context
): Promise<Response> {
  const response = await context.next();
  const reader = matchReader(request.headers.get('User-Agent'));
  const url = new URL(request.url);

  // Logged for every feed request, including the 304s that make up most steady-state feed
  // traffic, so the reader list can be maintained from real data.
  console.info(
    requestLogLine(
      request,
      context,
      `${request.method} ${url.pathname}`,
      `→ ${response.status}`,
      reader ?? UNMATCHED_LABEL
    )
  );

  // Only a successful XML body can be rewritten. Conditional GETs (304, no body) pass
  // through untouched, which is correct: the reader already holds a copy labelled with its
  // own source from an earlier fetch.
  if (!response.ok || !isXml(response)) return response;

  const headers = withCacheGuards(new Headers(response.headers));

  // Unrecognized reader: leave the body alone so the link keeps the build-time
  // `utm_source=Feed`. Passing the encoded stream straight through keeps the inherited
  // content-encoding/content-length headers accurate.
  if (!reader) {
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers,
    });
  }

  const body = await response.text();
  // Reading the body decodes it, so the inherited encoding/length headers now describe the
  // wrong bytes. Drop them and let the runtime set them for the string we return.
  headers.delete('content-encoding');
  headers.delete('content-length');

  return new Response(
    body.replaceAll(
      SOURCE_ANCHOR,
      `utm_source=${encodeURIComponent(reader)}&amp;`
    ),
    { status: response.status, statusText: response.statusText, headers }
  );
}

export const config: Config = {
  // If this function ever crashes, never break the feed: bypass the error so the request
  // chain continues and the unmodified feed is served. The crash is still written to the
  // edge function logs. This function only relabels an analytics param — it must never cost
  // a reader its feed.
  onError: 'bypass',
  // The main feed, plus the per-tag feeds Middleman proxies to `<tag path>feed.xml`
  // (config.rb). Scoped to the feeds themselves so tag *pages* don't pay for an invocation.
  path: ['/feed.xml', '/tagged/*/feed.xml'],
};
