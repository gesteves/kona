# Applies the SmartyPants typography to the draft of a social post: curly quotation marks, a true
# ellipsis, and an en or em dash, from the characters that a person types on a keyboard.
#
# It is not an ApplicationService, because that base class is for HTTP integrations and this class
# makes no network call. Each method is a class method, thus a caller needs no instance.
#
# ⚠️ **It is the SAME typography as the blog**, through `MarkdownHelper#smartypants`. The owner
# writes for one voice, thus a post and the article that it links to must not use a different
# apostrophe. Do not write a second set of rules here.
#
# ⚠️ **A URL goes through with NO change**, and that is the whole reason that this class exists and
# the helper is not called directly. SmartyPants reads the characters of an address as punctuation:
# `example.com/a--b` becomes an en dash, `?q="a"` becomes curly quotation marks, and `/a...b`
# becomes an ellipsis. Each of those gives a link that is dead, and nothing reports it.
class Typography
  # ⚠️ It extends the helper, thus this class cannot hold a rule of its own. Refer to the ⚠️ above.
  extend MarkdownHelper

  # What each address becomes while SmartyPants reads the text. U+FFFC is OBJECT REPLACEMENT
  # CHARACTER, which is what it names: one character that stands for something that is not text.
  #
  # ⚠️ **The mask is necessary, and a split at each address is NOT enough.** SmartyPants decides the
  # direction of a quotation mark from the characters at each side of it, thus it must read the
  # whole sentence at one time. With a split, `He said "see <link> now"` opens the quotation and
  # never closes it: the two marks are in different pieces.
  PLACEHOLDER = "\uFFFC".freeze

  class << self
    # @param text [String, nil] The words that the owner wrote.
    # @return [String] The same words, with the typography of the site.
    def apply(text)
      # ⚠️ A draft of its own cannot hold the mask, or the addresses would go back in the wrong
      # places. That character is not text and it renders as nothing, thus this loses no words.
      text = text.to_s.delete(PLACEHOLDER)
      return text if text.empty?

      urls = []
      converted = convert(mask(text, urls))

      # ⚠️ **It gives the words back with NO typography when a mask went missing.** A post with a
      # straight apostrophe is a small thing, and an address that another address replaced is a
      # link that goes to the wrong page.
      return text unless converted.count(PLACEHOLDER) == urls.length

      index = -1
      converted.gsub(PLACEHOLDER) { urls[index += 1] }
    end

    private

    # Writes the text with one mask in place of each address, and collects those addresses.
    # @param text [String]
    # @param urls [Array<String>] Filled in, in the order that the addresses appear.
    # @return [String]
    def mask(text, urls)
      masked = +""
      last = 0

      url_ranges(text).each do |range|
        masked << text[last...range.begin] << PLACEHOLDER
        urls << text[range]
        last = range.end
      end

      masked << text[last..].to_s
    end

    # ⚠️ **SmartyPants writes HTML entities**, because it is a renderer of HTML: it gives `&rsquo;`
    # and not `’`. A post holds characters, thus the decode is necessary and not decoration.
    # `MarkdownHelper#markdown_to_plain_text` decodes for the same reason.
    # @param chunk [String]
    # @return [String]
    def convert(chunk)
      return chunk if chunk.empty?

      HTMLEntities.new.decode(smartypants(chunk).to_s)
    end

    # ⚠️ It uses the URL pattern of Bluesky, which is the one that decides a link facet. Thus a
    # string that becomes a link there is an address here, and one pattern holds that rule.
    # `SocialMentions` reads it for the same reason.
    #
    # ⚠️ It covers the address of a Markdown link as well. `](https://…)` and a `[name]: https://…`
    # definition each put the address after a character that is not a word character, thus the
    # pattern finds both.
    # @param text [String]
    # @return [Array<Range>] The character ranges of each address, in order.
    def url_ranges(text)
      ranges = []
      text.scan(Bluesky::URL_PATTERN) do
        start_char, end_char = Regexp.last_match.offset(1)
        ranges << (start_char...end_char)
      end
      ranges
    end
  end
end
