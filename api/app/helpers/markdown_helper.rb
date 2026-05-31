require "redcarpet"

module MarkdownHelper
  # Converts Markdown to HTML with SmartyPants typography. Used to render the weather
  # summary (which emits **bold** for the location and race-day note).
  def markdown_to_html(text)
    return if text.blank?
    renderer = Redcarpet::Render::HTML.new(with_toc_data: true)
    markdown = Redcarpet::Markdown.new(renderer, fenced_code_blocks: true, disable_indented_code_blocks: true, tables: true, autolink: true, superscript: true)
    Redcarpet::Render::SmartyPants.render(markdown.render(text))
  end

  # Applies SmartyPants typography (curly quotes, em dashes) to a plain string, without
  # Markdown block rendering — used for inline text like event titles.
  # @param text [String, nil]
  # @return [String, nil]
  def smartypants(text)
    return if text.blank?
    Redcarpet::Render::SmartyPants.render(text)
  end
end
