// Resolves the card title by fetching the page and reading its own `og:title` meta tag —
// the single source of truth, set on the site by page_title(meta_title_source). The service
// never renders caller-supplied text, so it can only ever produce cards for real, published
// pages on the allowlisted origin(s); there is no arbitrary-text vector to sign against.

// Allowed origins for the `url` param, from SITE_URL (comma-separated for preview + prod).
// A request whose url isn't on one of these is rejected before any fetch. The production
// host is never hardcoded — it comes from this env var.
const siteOrigins = (process.env.SITE_URL ?? '')
  .split(',')
  .map((u) => u.trim())
  .filter(Boolean)
  .map((u) => {
    try {
      return new URL(u).origin;
    } catch {
      return null;
    }
  })
  .filter(Boolean);

export function isAllowedOrigin(url) {
  return siteOrigins.length > 0 && siteOrigins.includes(url.origin);
}

// og:title's content is HTML-escaped in the markup (it's emitted through `h`), so decode the
// handful of entities that can appear in a title before it goes into the image.
function decodeEntities(text) {
  return text
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0*39;|&#x0*27;|&apos;/gi, "'")
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&#x([0-9a-f]+);/gi, (_, x) => String.fromCodePoint(parseInt(x, 16)));
}

const OG_TITLE_TAG = /<meta[^>]+property=["']og:title["'][^>]*>/i;
const CONTENT_ATTR = /content=["']([^"']*)["']/i;

// Fetches the page and extracts its og:title. Returns null when the page is unreachable,
// non-2xx, or carries no og:title. Bounded by a short timeout so a slow origin can't hang
// the render; `cache: 'no-store'` so a just-republished page isn't read from a stale copy.
export async function fetchOgTitle(url) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5000);
  try {
    const response = await fetch(url, {
      signal: controller.signal,
      cache: 'no-store',
      headers: { 'user-agent': 'kona-og' },
    });
    if (!response.ok) return null;
    const html = await response.text();
    const tag = html.match(OG_TITLE_TAG)?.[0];
    const content = tag?.match(CONTENT_ATTR)?.[1];
    return content ? decodeEntities(content) : null;
  } finally {
    clearTimeout(timer);
  }
}
