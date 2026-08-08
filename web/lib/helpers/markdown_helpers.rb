require 'redcarpet'
require 'sanitize'

module MarkdownHelpers
  # ⚠️ Must stay identical to the api's MarkdownHelper::EXTENSIONS. Both render the same article
  # summary onto the same page — the static card and the trending/related fragment swapped into it.
  EXTENSIONS = {
    fenced_code_blocks: true, disable_indented_code_blocks: true, tables: true, autolink: true, superscript: true
  }.freeze

  # Renders Markdown to HTML, with SmartyPants typography applied.
  # @param text [String] The Markdown to render.
  # @return [String, nil] The HTML, or nil for blank input.
  def markdown_to_html(text)
    return if text.blank?
    Redcarpet::Render::SmartyPants.render(markdown_parser.render(text))
  end

  # ⚠️ Per-thread, not a shared constant: Redcarpet parsers hold render state and aren't
  # thread-safe, and Middleman builds pages in parallel.
  # @return [Redcarpet::Markdown] The reused parser for this thread.
  def markdown_parser
    Thread.current[:kona_markdown_parser] ||=
      Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(with_toc_data: true), **EXTENSIONS)
  end

  # Applies SmartyPants typography to plain text.
  # @param text [String] The text to process.
  # @return [String, nil] The processed text, or nil for blank input.
  def smartypants(text)
    return if text.blank?
    Redcarpet::Render::SmartyPants.render(text)
  end
end
