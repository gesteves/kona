require 'redcarpet'

module MarkdownHelpers
  # Converts Markdown text to HTML, with additional formatting and SmartyPants rendering.
  # @param text [String] The Markdown text to be converted.
  # @return [String, nil] The HTML representation of the Markdown text, or nil if the text is blank.
  def markdown_to_html(text)
    return if text.blank?
    renderer = Redcarpet::Render::HTML.new(with_toc_data: true)
    markdown = Redcarpet::Markdown.new(renderer, fenced_code_blocks: true, disable_indented_code_blocks: true, tables: true, autolink: true, superscript: true)
    Redcarpet::Render::SmartyPants.render(markdown.render(text))
  end

  # Converts Markdown text to plain text by first converting to HTML and then stripping HTML tags.
  # @param text [String] The Markdown text to be converted.
  # @return [String] The plain text representation of the Markdown text.
  def markdown_to_text(text)
    strip_tags(markdown_to_html(text))
  end

  # Applies SmartyPants rendering to the provided text for typographic improvements.
  # @param text [String] The text to be processed with SmartyPants rendering.
  # @return [String] The text after SmartyPants rendering, or an empty string if the original text is blank.
  def smartypants(text)
    return '' if text.blank?
    Redcarpet::Render::SmartyPants.render(text)
  end
end
