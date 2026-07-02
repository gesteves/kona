require 'htmlentities'

module TextHelpers
  # Replaces the masculine ordinal indicator (º, U+00BA), often typed by mistake,
  # with the proper degree sign (°, U+00B0).
  # @param text [String] The text in which to fix the degree symbol.
  # @return [String, nil] The text with the correct degree sign, or nil if the text is blank.
  def fix_degrees(text)
    return if text.blank?
    text.gsub("º", "°")
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
