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
  # @return [String] A string with the items joined by commas, and 'and' before the last item.
  def comma_join_with_and(items)
    items.size <= 2 ? items.join(' and ') : [items[0..-2].join(', '), items[-1]].join(' and ')
  end
end
