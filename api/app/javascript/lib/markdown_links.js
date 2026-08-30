// The Markdown link grammar of the Social media composer.
//
// ⚠️ **MARKDOWN CONTRACT.** The three strings below are the sources of
// `MarkdownLinks::DEFINITION_SOURCE`, `MarkdownLinks::SPAN_SOURCE`, and
// `MarkdownLinks::URL_SOURCE`, character for character, and the two files read a draft the same
// way. `spec/contracts/markdown_links_contract_spec.rb` compares the strings AND runs this file
// against that class over the same drafts.
//
// The browser needs its own copy for two reasons. The count measures the text that **Bluesky**
// will get, and a link takes its address out of that text: `[my post](https://…)` is 7 characters
// and not 30. And the composer turns Mastodon and Threads off at the keystroke that makes the
// first link, because only Bluesky can take one.
//
// ⚠️ A difference between the two copies does NOT fail safe here, and that is why the contract
// spec runs both. A browser that renders a link that Ruby does not would show a count that is too
// small, and the action would then refuse a draft that the page called correct.
//
// ⚠️ No `u` flag on any of these, as in social_mentions.js.

export const DEFINITION_SOURCE = "[ ]{0,3}\\[([^\\[\\]]+)\\]:[ \\t]*(\\S+)[ \\t]*";
export const SPAN_SOURCE = "\\[([^\\[\\]]*)\\](?:\\(([^\\s()]+)\\)|\\[([^\\[\\]]*)\\])?";
export const URL_SOURCE = "https?://[^\\s<>]+";

// ⚠️ `^` and `$` with NO `m` flag, thus each one anchors the whole string. Ruby uses \A and \z for
// the same reason: a line anchor reads differently in the two languages, and the caller splits the
// text into lines itself.
const DEFINITION = new RegExp(`^${DEFINITION_SOURCE}$`);
const URL = new RegExp(`^${URL_SOURCE}$`);
// The space that a trim takes off each end, and a value that holds nothing else.
//
// ⚠️ **They name each character, and they do not use `\s` or `trim()`.** JavaScript reads `\s` as
// Unicode and Ruby reads it as ASCII, and `trim()` and `String#strip` differ the same way. Thus a
// label of one no-break space would be words in one file and nothing in the other, and the two
// would then write a different post.
const TRIM = /^[ \t\r\n]+|[ \t\r\n]+$/g;
const BLANK = /^[ \t\r\n]*$/;

/**
 * Reads a draft.
 *
 * ⚠️ **A link here carries its address and NO offset, and that is deliberate.** The server writes
 * the byte offsets of each Bluesky facet, and it counts in code points where JavaScript counts in
 * UTF-16 code units: one emoji of a family is 5 in Ruby and 8 here. Thus an offset from this file
 * would be a number that looks correct and is not, and nothing in the browser needs one. The count
 * needs the text, and the composer needs to know only whether a link is there.
 * @param {string} source The words that the owner wrote, with the Markdown in them.
 * @returns {{ text: string, links: Array<{url: string}> }}
 */
export function parse(source) {
  const [text, definitions] = splitDefinitions(source ?? "");

  return scan(text, definitions);
}

/**
 * @param {string} source
 * @returns {string} The plain text, which is what a post holds.
 */
export function render(source) {
  return parse(source).text;
}

/**
 * ⚠️ This is the ONE test of "the owner wrote Markdown", and the page and the action both use it.
 * A span that resolves to no address is not a link, thus a sentence with brackets in it does not
 * turn the other two networks off.
 * @param {string} source
 * @returns {boolean} True when the draft holds at least one link.
 */
export function hasLinks(source) {
  return parse(source).links.length > 0;
}

/**
 * Takes the definition lines out of the draft.
 *
 * ⚠️ A definition is a **whole line**, thus this splits the text and never replaces inside it.
 * @param {string} source
 * @returns {[string, Object<string, string>]} The text with no definition line, and the addresses.
 */
function splitDefinitions(source) {
  const definitions = {};
  const kept = [];

  source.replaceAll("\r\n", "\n").split("\n").forEach((line) => {
    const match = DEFINITION.exec(line);
    // ⚠️ A line whose address is not http or https is not a definition, thus it stays in the post
    // as the words that it is.
    if (match && isUrl(match[2])) {
      definitions[nameKey(match[1])] = match[2];
    } else {
      kept.push(line);
    }
  });

  return [trim(kept.join("\n")), definitions];
}

/**
 * Writes the plain text, and lists each link that it found.
 *
 * ⚠️ It is ONE left-to-right pass, thus a span that resolves to no address keeps its brackets and
 * the words around it are never lost.
 * @param {string} text The draft with no definition line.
 * @param {Object<string, string>} definitions
 * @returns {{ text: string, links: Array<{url: string}> }}
 */
function scan(text, definitions) {
  const pattern = new RegExp(SPAN_SOURCE, "g");
  const links = [];
  let out = "";
  let last = 0;
  let match;

  while ((match = pattern.exec(text)) !== null) {
    // A match of no length would never move the cursor.
    if (match[0].length === 0) {
      pattern.lastIndex += 1;
      continue;
    }

    const url = urlOf(match, definitions);
    // ⚠️ It leaves the span exactly as it is, brackets and all. The next match writes the words
    // between `last` and its own start, thus nothing is lost.
    if (url === null) continue;

    out += text.slice(last, match.index) + match[1];
    links.push({ url });
    last = match.index + match[0].length;
  }

  return { text: out + text.slice(last), links };
}

/**
 * Where one span points.
 * @param {RegExpExecArray} match
 * @param {Object<string, string>} definitions
 * @returns {string|null} The address, or null when the span is only words.
 */
function urlOf(match, definitions) {
  const [, label, inline, reference] = match;
  // A link with no words has nothing to press.
  if (isBlank(label)) return null;

  // ⚠️ `[words][]` and `[words]` both name the words, thus one branch covers the two.
  const name = isBlank(reference) ? label : reference;
  const url = inline ?? definitions[nameKey(name)];

  return isUrl(url) ? url : null;
}

/**
 * ⚠️ It folds the case, as CommonMark does: `[Name]: …` answers `[words][name]`.
 * @param {string} name
 * @returns {string}
 */
function nameKey(name) {
  return trim(name ?? "").toLowerCase();
}

/**
 * @param {string} value
 * @returns {string} The value with no space at either end. Refer to the ⚠️ on TRIM.
 */
function trim(value) {
  return value.replace(TRIM, "");
}

/**
 * @param {string|undefined} value
 * @returns {boolean} True when the value holds nothing but space.
 */
function isBlank(value) {
  return BLANK.test(value ?? "");
}

/**
 * @param {string|undefined} value
 * @returns {boolean} True when the value is an http or https address.
 */
function isUrl(value) {
  return URL.test(value ?? "");
}
