require "htmlentities"

module TextHelpers
  # Puts the degree sign (°) in place of the masculine ordinal indicator (º), which a person often
  # types by error.
  # @param text [String] The text to correct.
  # @return [String, nil] The text after the correction, or nil for a blank input.
  def fix_degrees(text)
    return if text.blank?
    text.gsub("º", "°")
  end

  # Renders the text and removes its markup, and only plain text stays.
  # @param text [String] The text to change.
  # @param escape_html_entities [Boolean] True to keep each entity in its escaped form, for example
  #   `&` as `&amp;`.
  # @return [String, nil] The plain text, or nil for a blank input.
  def sanitize(text, escape_html_entities: false)
    return if text.blank?
    text = Sanitize.fragment(markdown_to_html(text)).strip
    text = HTMLEntities.new.decode(text) unless escape_html_entities
    text
  end
end
