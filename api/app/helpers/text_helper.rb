module TextHelper
  # Puts the degree sign (°) in place of the masculine ordinal indicator (º), which a person often
  # types by error. This is the same as TextHelpers#fix_degrees of the static site: both apps render
  # the same summary text, and it must be the same in the page and in the widget fragment.
  # @param text [String, nil]
  # @return [String, nil]
  def fix_degrees(text)
    return if text.blank?
    text.gsub("º", "°")
  end

  # Puts a non-breaking space between the last two words, thus one word does not go alone onto the
  # last line.
  def remove_widows(text)
    return if text.blank?
    words = text.split(/\s+/)
    return text if words.size == 1
    last_words = words.pop(2).join("&nbsp;")
    words.append(last_words).join(" ")
  end

  # Joins the items into a string, with a comma between them and "and" before the last one.
  def comma_join_with_and(items, oxford = true)
    last_separator = oxford ? ", and " : " and "
    items.size <= 2 ? items.join(last_separator) : [ items[0..-2].join(", "), items[-1] ].join(last_separator)
  end

  # Puts the correct article, "a" or "an", before a word.
  def with_indefinite_article(word)
    word =~ /^(8|11|18|a|e|i|o|u)/i ? "an #{word}" : "a #{word}"
  end
end
