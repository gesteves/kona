# The rules of a post that each network shares: where an address is, how a link goes below the
# words, and how long a text is. Bluesky, Mastodon, Typography, and SocialMentions each read them
# here, thus the page and the post cannot count or compose differently.
module SocialText
  module_function

  # Each bare address, as character ranges. ⚠️ It is the URL pattern of Bluesky, which is the one
  # that decides a link facet. Thus a string that becomes a link there is an address everywhere.
  # @param text [String]
  # @return [Array<Range>]
  def url_ranges(text)
    text = text.to_s
    ranges = []

    text.scan(Bluesky::URL_PATTERN) do
      start_char, end_char = Regexp.last_match.offset(1)
      # ⚠️ The range is TRIMMED, thus the punctuation of the sentence after an address is outside
      # it and still gets its typography. Each reader of this method — the mask, the mentions, and
      # the facets — then agrees about where an address ends.
      url = Bluesky.trim_url(text[start_char...end_char])
      next if url.blank?

      ranges << (start_char...(start_char + url.length))
    end

    ranges
  end

  # The words, then the link below them.
  # @param text [String, nil]
  # @param url [String, nil]
  # @return [String]
  def compose(text:, url: nil)
    [ text.to_s.strip, url.to_s.strip ].reject(&:blank?).join("\n\n")
  end

  # The length in graphemes, which is how Bluesky counts and how a person reads. `String#length`
  # counts one emoji as more than one.
  # @param text [String, nil]
  # @return [Integer]
  def graphemes(text)
    text.to_s.scan(/\X/).length
  end
end
