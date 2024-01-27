require 'redcarpet'

module MarkdownHelpers
  def markdown_to_html(text)
    return if text.blank?
    renderer = Redcarpet::Render::HTML.new(with_toc_data: true)
    markdown = Redcarpet::Markdown.new(renderer, fenced_code_blocks: true, disable_indented_code_blocks: true, tables: true, autolink: true, superscript: true)
    Redcarpet::Render::SmartyPants.render(markdown.render(text))
  end

  def markdown_to_text(text)
    strip_tags(markdown_to_html(text))
  end

  def smartypants(text)
    return '' if text.blank?
    Redcarpet::Render::SmartyPants.render(text)
  end
end
