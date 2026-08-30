# Reads the Markdown links of a draft on the Social media page, and gives the plain text that a
# post holds with the offsets of each label in it.
#
# It is not an ApplicationService, because that base class is for HTTP integrations and this class
# makes no network call. Each method is a class method, thus a caller needs no instance.
#
# ⚠️ **Only Bluesky can take one of these.** Its rich text puts the address in a facet, thus the
# words carry the link and the URL uses none of the 300 characters. Mastodon and Threads have no
# equivalent: their text is plain, thus a link there must be an address that a reader can see.
# `Admin::SocialController` refuses a draft that holds a link and posts to one of those two.
#
# ⚠️ **This is a small grammar and not a Markdown renderer.** It knows a link and nothing else: no
# emphasis, no heading, no code, and no escape. A post is 300 characters, and each other rule of
# Markdown would only make a plain sentence into markup that the owner did not ask for.
#
# The three forms:
#
#   [words](https://example.com)          inline
#   [words][name] … [name]: https://…     a reference, and its definition on a line of its own
#   [name] … [name]: https://…            a short reference, where the words are the name
#
# ⚠️ **The address must be http or https, and a span with anything else stays as it is.** Thus
# "I ate [a lot](really)" keeps its brackets and its parentheses, and it is not a link.
class MarkdownLinks
  # ⚠️ **Each pattern here is a STRING first, and a Regexp second.**
  # app/javascript/lib/markdown_links.js holds the same strings, because the character count in the
  # browser must measure the text that this class makes. An interpolated Ruby Regexp gives a source
  # with `(?-mix:…)` in it, which JavaScript cannot parse, thus a string is the only shape that the
  # two can share. spec/contracts/markdown_links_contract_spec.rb compares them, and it also runs
  # the two files over the same drafts.

  # One definition line: `[name]: https://example.com`. ⚠️ It matches ONE line, and the caller
  # anchors it: Ruby uses \A and \z, and the browser uses ^ and $ with no `m` flag. Thus neither
  # one depends on how its language reads a line anchor.
  DEFINITION_SOURCE = "[ ]{0,3}\\[([^\\[\\]]+)\\]:[ \\t]*(\\S+)[ \\t]*".freeze

  # One span: the words in brackets, and then an inline address or the name of a definition.
  # ⚠️ The second part is OPTIONAL, and that is the short form: `[name]` alone is a link when a
  # definition names it, and it is ordinary words when nothing does.
  SPAN_SOURCE = "\\[([^\\[\\]]*)\\](?:\\(([^\\s()]+)\\)|\\[([^\\[\\]]*)\\])?".freeze

  # The addresses that a link can hold. ⚠️ It is the thing that keeps an ordinary sentence out of
  # this grammar: a span whose address is not http or https stays as the owner wrote it.
  URL_SOURCE = "https?://[^\\s<>]+".freeze

  DEFINITION_PATTERN = /\A#{DEFINITION_SOURCE}\z/
  SPAN_PATTERN = Regexp.new(SPAN_SOURCE)
  URL_PATTERN = /\A#{URL_SOURCE}\z/

  # The space that a trim takes off each end of the text, and a value that holds nothing else.
  #
  # ⚠️ **They name each character, and they do not use `\s`, `String#strip`, or `#blank?`.** Ruby
  # reads `\s` as ASCII and JavaScript reads it as Unicode, and `strip` and `trim()` differ the
  # same way. Thus a label of one no-break space would be words in one file and nothing in the
  # other, and the two would then write a different post.
  TRIM_PATTERN = /\A[ \t\r\n]+|[ \t\r\n]+\z/
  BLANK_PATTERN = /\A[ \t\r\n]*\z/

  # One link of a post: where its words are in the plain text, and where it points.
  #
  # ⚠️ `start` and `finish` are CHARACTER offsets. `Bluesky#markdown_facets` makes the byte offsets
  # that a facet needs, and the two are not the same: one accented letter is 1 character and 2
  # bytes.
  Link = Data.define(:start, :finish, :url)

  # The plain text of a draft, and each link in it.
  Result = Data.define(:text, :links)

  class << self
    # Reads a draft.
    # @param source [String, nil] The words that the owner wrote, with the Markdown in them.
    # @return [Result]
    def parse(source)
      text, definitions = split_definitions(source.to_s)
      scan(text, definitions)
    end

    # @param source [String, nil]
    # @return [String] The plain text, which is what a post holds.
    def render(source) = parse(source).text

    # ⚠️ This is the ONE test of "the owner wrote Markdown", and the page and the action both use
    # it. A span that resolves to no address is not a link, thus a sentence with brackets in it
    # does not turn the other two networks off.
    # @param source [String, nil]
    # @return [Boolean] True when the draft holds at least one link.
    def links?(source) = parse(source).links.any?

    private

    # Takes the definition lines out of the draft.
    #
    # ⚠️ A definition is a **whole line**, thus this splits the text and never replaces inside it.
    # The line goes away with its newline, and the trim then takes the blank line that is left at
    # the end. Without that a post would carry the empty lines of its own syntax.
    # @param source [String]
    # @return [Array(String, Hash)] The text with no definition line, and the addresses by name.
    def split_definitions(source)
      definitions = {}
      kept = []

      source.gsub("\r\n", "\n").split("\n", -1).each do |line|
        match = DEFINITION_PATTERN.match(line)
        # ⚠️ A line whose address is not http or https is not a definition, thus it stays in the
        # post as the words that it is.
        if match && url?(match[2])
          definitions[name_key(match[1])] = match[2]
        else
          kept << line
        end
      end

      [ trim(kept.join("\n")), definitions ]
    end

    # Writes the plain text, and notes where each label is in it.
    #
    # ⚠️ It is ONE left-to-right pass, and the offsets come from the text that it is writing. Thus
    # two links with the same words each get their own offsets. To search the finished text for a
    # label, which is what a renderer with a separate HTML step must do, gives a facet over the
    # first occurrence of it and not over the link.
    # @param text [String] The draft with no definition line.
    # @param definitions [Hash]
    # @return [Result]
    def scan(text, definitions)
      out = +""
      links = []
      last = 0

      text.scan(SPAN_PATTERN) do
        match = Regexp.last_match
        url = url_of(match, definitions)
        # ⚠️ It leaves the span exactly as it is, brackets and all. The next match writes the words
        # between `last` and its own start, thus nothing is lost.
        next if url.nil?

        out << text[last...match.begin(0)]
        start = out.length
        out << match[1]
        links << Link.new(start: start, finish: out.length, url: url)
        last = match.end(0)
      end

      Result.new(text: out + text[last..].to_s, links: links)
    end

    # Where one span points.
    # @param match [MatchData] A match of SPAN_PATTERN.
    # @param definitions [Hash]
    # @return [String, nil] The address, or nil when the span is only words.
    def url_of(match, definitions)
      label, inline, reference = match[1], match[2], match[3]
      # A link with no words has nothing to press.
      return nil if blank?(label)

      # ⚠️ `[words][]` and `[words]` both name the words, thus one branch covers the two.
      name = blank?(reference) ? label : reference
      url = inline || definitions[name_key(name)]
      url if url?(url)
    end

    # ⚠️ It folds the case, as CommonMark does: `[Name]: …` answers `[words][name]`.
    # @param name [String]
    # @return [String]
    def name_key(name) = trim(name.to_s).downcase

    # @param value [String, nil]
    # @return [String] The value with no space at either end. Refer to the ⚠️ on TRIM_PATTERN.
    def trim(value) = value.to_s.gsub(TRIM_PATTERN, "")

    # @param value [String, nil]
    # @return [Boolean] True when the value holds nothing but space.
    def blank?(value) = BLANK_PATTERN.match?(value.to_s)

    # @param value [String, nil]
    # @return [Boolean] True when the value is an http or https address.
    def url?(value) = URL_PATTERN.match?(value.to_s)
  end
end
