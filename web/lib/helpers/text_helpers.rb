require 'htmlentities'

module TextHelpers
  # Replaces the masculine ordinal indicator (º), often typed by mistake, with the degree
  # sign (°).
  # @param text [String] The text to fix.
  # @return [String, nil] The fixed text, or nil for blank input.
  def fix_degrees(text)
    return if text.blank?
    text.gsub("º", "°")
  end

  # Renders text and strips its markup, leaving plain text.
  # @param text [String] The text to sanitize.
  # @param escape_html_entities [Boolean] Whether to leave entities escaped, e.g. `&` as `&amp;`.
  # @return [String, nil] The plain text, or nil for blank input.
  def sanitize(text, escape_html_entities: false)
    return if text.blank?
    text = Sanitize.fragment(markdown_to_html(text)).strip
    text = HTMLEntities.new.decode(text) unless escape_html_entities
    text
  end
end
