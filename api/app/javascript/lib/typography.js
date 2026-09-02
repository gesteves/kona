// The part of the SmartyPants typography that changes the LENGTH of a post.
//
// ⚠️ **This file is for the COUNT, and it must never render text that a person reads.** It writes
// the ellipsis and the two dashes and it leaves every quotation mark straight. The server, through
// `Typography` and `MarkdownHelper#smartypants`, is the one place that writes the true text.
//
// ⚠️ **A quotation mark is why that split is safe.** `"` becomes `“` or `”` and `'` becomes `’`,
// and each of those is ONE character in place of one. Thus the direction of a quotation mark, which
// is the hard half of SmartyPants and the half that no small copy can match, cannot change a count.
// A measurement against Redcarpet gave the same length for every quotation shape.
//
// The rules below are what is left, and each one is context-free:
//
//   ...  or  . . .   ->  …     (three characters, or three with ONE space between each, become one)
//   ---                ->  —
//   --                 ->  –
//
// ⚠️ The dashes run LONGEST FIRST, as Redcarpet does. Four dashes give `—-` and five give `—–`.
//
// ⚠️ An address goes through with NO change, exactly as `Typography` leaves it alone: a link that
// holds `--` must keep it, and a count that shortened one would be smaller than the server's.

import { TOKEN_SOURCE, URL_SOURCE } from "./social_mentions";

const ELLIPSIS = /\.\.\.|\. \. \./g;
const EM_DASH = /---/g;
const EN_DASH = /--/g;
// The marks and the fractions that SmartyPants writes as one character.
const COPYRIGHT = /\(c\)/gi;
const REGISTERED = /\(r\)/gi;
const TRADEMARK = /\(tm\)/gi;
const FRACTIONS = /(?<![\d/])(1\/4|1\/2|3\/4)(?![\d/])/g;
const FRACTION_CHARS = { "1/4": "¼", "1/2": "½", "3/4": "¾" };

/**
 * Applies the rules that change the length of a post.
 *
 * ⚠️ For the count only. Refer to the ⚠️ at the top of this file.
 * @param {string} text
 * @returns {string} The text at the length that the server will post.
 */
export function applyLengthRules(text) {
  const body = text ?? "";
  if (!body) return body;

  let out = "";
  let last = 0;

  for (const [start, end] of maskedRanges(body)) {
    out += convert(body.slice(last, start)) + body.slice(start, end);
    last = end;
  }

  return out + convert(body.slice(last));
}

/**
 * @param {string} chunk A piece of the text that holds no address.
 * @returns {string}
 */
function convert(chunk) {
  return chunk
    .replace(ELLIPSIS, "…")
    .replace(EM_DASH, "—")
    .replace(EN_DASH, "–")
    .replace(COPYRIGHT, "©")
    .replace(REGISTERED, "®")
    .replace(TRADEMARK, "™")
    .replace(FRACTIONS, (match) => FRACTION_CHARS[match]);
}

/**
 * Each address and each mention token, in order. ⚠️ A handle can hold `--`, and the server keeps
 * it: `Typography#masked_ranges` masks the same two shapes.
 * @param {string} text
 * @returns {Array<[number, number]>}
 */
function maskedRanges(text) {
  const urls = groupRanges(text, URL_SOURCE);
  const tokens = groupRanges(text, TOKEN_SOURCE).filter(
    ([start]) => !urls.some(([from, to]) => start >= from && start < to)
  );
  return [...urls, ...tokens].sort((a, b) => a[0] - b[0]);
}

/**
 * The character ranges of group 1 of a pattern.
 * @param {string} text
 * @param {string} source
 * @returns {Array<[number, number]>}
 */
function groupRanges(text, source) {
  const pattern = new RegExp(source, "g");
  const ranges = [];
  let match;

  while ((match = pattern.exec(text)) !== null) {
    const start = match.index + match[0].length - match[1].length;
    ranges.push([start, start + match[1].length]);
    if (match.index === pattern.lastIndex) pattern.lastIndex += 1;
  }
  return ranges;
}
