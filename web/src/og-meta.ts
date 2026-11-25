// Reads the Open Graph tags of a page from its markup, for the card route in src/og.ts.

/**
 * Decodes the HTML entities that an og:title can contain.
 * `&amp;` comes last: if it came first, `&amp;lt;` would become `<` in a second pass.
 *
 * ⚠️ This is necessary with HTMLRewriter. `Element#getAttribute` gives the attribute **as the
 * source writes it**, with the entities. It does not decode them.
 */
function decodeEntities(text: string): string {
  return text
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0*39;|&#x0*27;|&apos;/gi, "'")
    .replace(/&#(\d+);/g, (match, d: string) => fromCodePoint(d, 10, match))
    .replace(/&#x([0-9a-f]+);/gi, (match, x: string) =>
      fromCodePoint(x, 16, match)
    )
    .replace(/&amp;/g, '&');
}

/**
 * Decodes one numeric character reference. If it cannot, it returns `match`, the full entity
 * text, with no change.
 *
 * ⚠️ A code point outside the range makes `String.fromCodePoint` raise, and this runs on the path
 * of the OG route that catches nothing. One bad entity in an `og:title` would 500 the card.
 * @param raw The digits of the entity.
 */
function fromCodePoint(raw: string, radix: number, match: string): string {
  const n = parseInt(raw, radix);
  if (!Number.isInteger(n) || n < 0 || n > 0x10ffff) return match;
  return String.fromCodePoint(n);
}

/** The og:title and the og:image of a page. Each is null when the page has no such tag. */
type OgMeta = { title: string | null; image: string | null };

/**
 * Reads the og:title and the og:image of a page from its markup.
 *
 * This uses HTMLRewriter on a stream, and it does not buffer the page. An article page is large,
 * this route is near the Worker CPU limit, and the tags are in `<head>`. Thus the read stops when
 * it has both tags, or at the end of `<head>`.
 * @returns The title and the image URL, each one decoded.
 */
export async function readOgMeta(response: Response): Promise<OgMeta> {
  let title: string | null = null;
  let image: string | null = null;
  let headEnded = false;

  const transformed = new HTMLRewriter()
    .on('meta[property="og:title"]', {
      element(element) {
        title ??= element.getAttribute('content');
      },
    })
    .on('meta[property="og:image"]', {
      element(element) {
        image ??= element.getAttribute('content');
      },
    })
    .on('head', {
      element(element) {
        element.onEndTag(() => {
          headEnded = true;
        });
      },
    })
    .transform(response);

  const reader = transformed.body?.getReader();
  if (!reader) return { title: null, image: null };

  try {
    while (!headEnded && (title === null || image === null)) {
      const { done } = await reader.read();
      if (done) break;
    }
  } finally {
    await reader.cancel();
  }

  return {
    title: title === null ? null : decodeEntities(title),
    image: image === null ? null : decodeEntities(image),
  };
}

/**
 * Reads the og:title of a page from its markup. Only the tests call this.
 * @returns The decoded title, or null if the page has no og:title.
 */
export async function readOgTitle(response: Response): Promise<string | null> {
  return (await readOgMeta(response)).title;
}
