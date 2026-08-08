module TextHelper
  # Replaces the masculine ordinal indicator (º), often typed by mistake, with the degree sign (°).
  # Mirrors the static site's TextHelpers#fix_degrees — the same summary text is rendered by both
  # apps and has to read identically in the page and in the widget fragment.
  # @param text [String, nil]
  # @return [String, nil]
  def fix_degrees(text)
    return if text.blank?
    text.gsub("º", "°")
  end

  # Replaces the space between the last two words with a non-breaking space to prevent widows.
  def remove_widows(text)
    return if text.blank?
    words = text.split(/\s+/)
    return text if words.size == 1
    last_words = words.pop(2).join("&nbsp;")
    words.append(last_words).join(" ")
  end

  # Joins items into a string with commas and "and".
  def comma_join_with_and(items, oxford = true)
    last_separator = oxford ? ", and " : " and "
    items.size <= 2 ? items.join(last_separator) : [ items[0..-2].join(", "), items[-1] ].join(last_separator)
  end

  # Prefixes a word with the appropriate indefinite article ("a"/"an").
  def with_indefinite_article(word)
    word =~ /^(8|11|18|a|e|i|o|u)/i ? "an #{word}" : "a #{word}"
  end
end
