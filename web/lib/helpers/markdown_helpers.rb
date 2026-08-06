require 'redcarpet'
require 'sanitize'

module MarkdownHelpers
  # Renders Markdown to HTML, with SmartyPants typography applied.
  # @param text [String] The Markdown to render.
  # @return [String, nil] The HTML, or nil for blank input.
  def markdown_to_html(text)
    return if text.blank?
    renderer = Redcarpet::Render::HTML.new(with_toc_data: true)
    markdown = Redcarpet::Markdown.new(renderer, fenced_code_blocks: true, disable_indented_code_blocks: true, tables: true, autolink: true, superscript: true)
    Redcarpet::Render::SmartyPants.render(markdown.render(text))
  end

  # Applies SmartyPants typography to plain text.
  # @param text [String] The text to process.
  # @return [String, nil] The processed text, or nil for blank input.
  def smartypants(text)
    return if text.blank?
    Redcarpet::Render::SmartyPants.render(text)
  end
end
