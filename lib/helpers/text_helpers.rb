require 'nokogiri'

module TextHelpers
  # Replaces the space between the last two words of a text with a non-breaking space to prevent widow words.
  # @param text [String] The text in which to prevent widows.
  # @return [String, nil] The text with a non-breaking space between the last two words, or nil if the text is blank.
  def remove_widows(text)
    return if text.blank?

    # Parse the string as HTML fragment
    doc = Nokogiri::HTML.fragment(text)
    text_nodes = doc.search('.//text()')

    if text_nodes.empty?
      # Handle plain text
      words = text.split(/\s+/)
      insert_nbsp_between_last_two_words(words)
    else
      # Handle HTML
      last_text_node = text_nodes.last
      words = last_text_node.content.split(/\s+/)
      last_text_node.content = insert_nbsp_between_last_two_words(words)
    end

    doc.to_html
  end

  def insert_nbsp_between_last_two_words(words)
    return words.join(' ') if words.size <= 1

    words[-2] += '&nbsp;' + words.pop
    words.join(' ')
  end

  # Joins an array of items into a string, using commas and 'and' appropriately.
  # @param items [Array<String>] The array of items to be joined into a string.
  # @return [String] A string with the items joined by commas, and 'and' before the last item.
  def comma_join_with_and(items)
    items.size <= 2 ? items.join(' and ') : [items[0..-2].join(', '), items[-1]].join(' and ')
  end

  # Determines the appropriate indefinite article ('a' or 'an') to use with a word.
  # @param word [String] The word to prepend with an article.
  # @return [String] The word prefixed with the appropriate indefinite article.
  def add_indefinite_article(word)
    word =~ /^(8|11|18|a|e|i|o|u)/i ? "an #{word}" : "a #{word}"
  end
  
end
