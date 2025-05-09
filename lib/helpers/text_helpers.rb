require 'htmlentities'

module TextHelpers
  # Replaces the space between the last two words of a text with a non-breaking space to prevent widow words.
  # @param text [String] The text in which to prevent widows.
  # @return [String, nil] The text with a non-breaking space between the last two words, or nil if the text is blank.
  def remove_widows(text)
    return if text.blank?
    words = text.split(/\s+/)
    return text if words.size == 1
    last_words = words.pop(2).join('&nbsp;')
    words.append(last_words).join(' ')
  end

  # Joins an array of items into a string, using commas and 'and' appropriately.
  # @param items [Array<String>] The array of items to be joined into a string.
  # @param oxford [Boolean] (Optional) Whether to use the Oxford comma before the last item. Default is true.
  # @return [String] A string with the items joined by commas, and 'and' before the last item.
  def comma_join_with_and(items, oxford = true)
    last_separator = oxford ? ', and ' : ' and '
    items.size <= 2 ? items.join(last_separator) : [items[0..-2].join(', '), items[-1]].join(last_separator)
  end

  # Determines the appropriate indefinite article ('a' or 'an') to use with a word.
  # @param word [String] The word to prepend with an article.
  # @return [String] The word prefixed with the appropriate indefinite article.
  def with_indefinite_article(word)
    word =~ /^(8|11|18|a|e|i|o|u)/i ? "an #{word}" : "a #{word}"
  end

  # Sanitizes a given text by removing any HTML tags, and optionally decoding HTML entities.
  # @param text [String] The text to be sanitized.
  # @param escape_html_entities [Boolean] Whether to escape HTML entities in the sanitized text, for example `&` to `&amp;`. Defaults to false.
  # @return [String] The sanitized text, with HTML tags removed and optionally HTML entities decoded.
  def sanitize(text, escape_html_entities: false)
    return if text.blank?
    text = Sanitize.fragment(markdown_to_html(text)).strip
    text = HTMLEntities.new.decode(text) unless escape_html_entities
    text
  end
end
