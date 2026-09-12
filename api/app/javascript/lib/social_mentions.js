// The mention patterns of the Social media composer, and the substitution that the character
// count needs.
//
// ⚠️ **MENTION CONTRACT.** The three strings below are the sources of
// `SocialMentions::TOKEN_SOURCE`, `SocialMentions::DOMAIN_SOURCE`, and `Bluesky::URL_PATTERN`,
// character for character. `spec/contracts/social_mentions_contract_spec.rb` compares them.
//
// The browser needs its own copy because the count must follow each keystroke, and the count
// measures the text that **Bluesky** will get: a mention grows into a handle, thus a count of the
// raw words would say that a draft fits when Bluesky refuses it.
//
// ⚠️ A difference between the two copies fails SAFE in both directions. A token that only the
// browser finds gives a row that the action ignores. A token that only Ruby finds gets no row,
// thus it has no value, thus the action removes its "@" and keeps the word. Neither one can tag
// the wrong account.
//
// ⚠️ No `u` flag on any of these. These patterns index by UTF-16 code unit, as the ranges that
// read them do, and `u` would change that.

export const TOKEN_SOURCE = "(?:^|[$|\\W])(@[a-zA-Z0-9](?:[a-zA-Z0-9._-]*[a-zA-Z0-9])?(?:@[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?)?)";
export const DOMAIN_SOURCE = "(?:[a-zA-Z0-9](?:[a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?\\.)+[a-zA-Z](?:[a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?";
export const URL_SOURCE = "(?:^|[$|\\W])(https?://\\S+)";

// A Bluesky handle is a domain. ⚠️ It is the ONE shape that this file knows, because the count
// only ever measures the Bluesky text. The other two networks are the concern of the server.
const BLUESKY_HANDLE = new RegExp(`^${DOMAIN_SOURCE}$`);

/**
 * @param {string} value A handle, with no leading "@".
 * @returns {boolean} True when it has the shape of a Bluesky handle, which is a domain.
 */
export function isBlueskyHandle(value) {
  return BLUESKY_HANDLE.test(value ?? "");
}

// The punctuation of a sentence at the end of an address, and the characters that close something
// that holds it. ⚠️ They are the copy of `Bluesky::URL_TRAILING_PUNCTUATION` and
// `Bluesky::URL_TRAILING_WRAPPERS`, because `URL_SOURCE` takes each character up to a space and
// `Bluesky.trim_url` is what decides where an address ends.
const URL_TRAILING_PUNCTUATION = /[.,;:!?]+$/;
const URL_TRAILING_WRAPPERS = { ")": "(", "]": "[", ">": "<" };

/**
 * Removes the punctuation of the sentence from the end of an address.
 *
 * ⚠️ A closing bracket comes off only when the address holds no opening one, thus
 * `…/Kona_(Hawaii)` keeps its bracket and `(see …/a)` gives up the one that closes the aside.
 * @param {string} url The address, as the pattern matched it.
 * @returns {string} The address alone.
 */
export function trimUrl(url) {
  let out = String(url ?? "").replace(URL_TRAILING_PUNCTUATION, "");

  while (URL_TRAILING_WRAPPERS[out.at(-1)] && !out.includes(URL_TRAILING_WRAPPERS[out.at(-1)])) {
    out = out.slice(0, -1).replace(URL_TRAILING_PUNCTUATION, "");
  }

  return out;
}

/**
 * The character ranges of each address, with the punctuation of the sentence outside them.
 *
 * ⚠️ `SocialText.url_ranges` trims the same way. Thus the mask of the typography, the mentions
 * that it skips, and the facets of a post all agree about where an address ends.
 * @param {string} text
 * @returns {Array<[number, number]>}
 */
export function urlRanges(text) {
  const ranges = [];

  for (const [start, end] of groupRanges(text ?? "", URL_SOURCE)) {
    const url = trimUrl(String(text ?? "").slice(start, end));
    if (url === "") continue;

    ranges.push([start, start + url.length]);
  }
  return ranges;
}

/**
 * The character ranges of the first group of each match.
 * @param {string} text
 * @param {string} source A pattern whose first group ends the match.
 * @returns {Array<[number, number]>}
 */
function groupRanges(text, source) {
  const pattern = new RegExp(source, "g");
  const ranges = [];
  let match;

  while ((match = pattern.exec(text)) !== null) {
    const start = match.index + match[0].length - match[1].length;
    ranges.push([start, start + match[1].length]);
    // A match of no length would never move the cursor.
    if (match.index === pattern.lastIndex) pattern.lastIndex += 1;
  }
  return ranges;
}

/**
 * Each mention token of a text, in order, with its "@" and the spelling of the owner.
 *
 * ⚠️ A token inside a URL is not a token: to replace one would break the address.
 * @param {string} text
 * @returns {string[]}
 */
export function tokensOf(text) {
  const body = text ?? "";
  const skip = urlRanges(body);

  return groupRanges(body, TOKEN_SOURCE)
    .filter(([start]) => !skip.some(([from, to]) => start >= from && start < to))
    .map(([start, end]) => body.slice(start, end));
}

/**
 * The key of a token in the mention map. ⚠️ It folds the case, as SocialMentions.key does.
 * @param {string} token
 * @returns {string}
 */
export function mentionKey(token) {
  return (token ?? "").replace(/^@/, "").toLowerCase();
}

/**
 * The words that go in place of one token, for Bluesky.
 * @param {string} token
 * @param {string|undefined} value
 * @returns {string}
 */
// ⚠️ It names each character, as markdown_links.js does. `trim()` reads Unicode space and
// `String#strip` reads ASCII space, thus a value with a no-break space at its end would be a
// handle in one file and words in the other.
const TRIM = /^[ \t\r\n\f\v]+|[ \t\r\n\f\v]+$/g;

function replacement(token, value) {
  const raw = (value ?? "").replace(TRIM, "");
  if (!raw) return token.replace(/^@/, "");

  const handle = raw.replace(/^@+/, "");
  if (BLUESKY_HANDLE.test(handle)) return `@${handle}`;

  // ⚠️ Plain words carry no "@" at all. It is the rule of SocialMentions.replacement.
  return raw.replaceAll("@", "");
}

/**
 * The text of a post as Bluesky will get it. The count measures this and not the raw words.
 *
 * ⚠️ It is ONE left-to-right pass, and never a replace for each entry of the map: a handle that
 * one pass wrote would be matched again by a later token.
 * @param {string} text
 * @param {Object<string, string>} values The Bluesky field of each mention, by key.
 * @returns {string}
 */
export function blueskyText(text, values) {
  const body = text ?? "";
  const skip = urlRanges(body);
  let out = "";
  let last = 0;

  for (const [start, end] of groupRanges(body, TOKEN_SOURCE)) {
    if (skip.some(([from, to]) => start >= from && start < to)) continue;

    const token = body.slice(start, end);
    out += body.slice(last, start) + replacement(token, values?.[mentionKey(token)]);
    last = end;
  }
  return out + body.slice(last);
}
