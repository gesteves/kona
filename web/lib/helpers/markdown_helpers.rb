require "redcarpet"
require "sanitize"

module MarkdownHelpers
  # ⚠️ This must stay the same as MarkdownHelper::EXTENSIONS of the api. Both render the same article
  # summary onto the same page: the static card, and the trending or related fragment that replaces
  # it.
  EXTENSIONS = {
    fenced_code_blocks: true, disable_indented_code_blocks: true, tables: true, autolink: true, superscript: true
  }.freeze

  # Renders Markdown as HTML, with the SmartyPants typography.
  # @param text [String] The Markdown to render.
  # @return [String, nil] The HTML, or nil for a blank input.
  def markdown_to_html(text)
    return if text.blank?
    Redcarpet::Render::SmartyPants.render(markdown_parser.render(text))
  end

  # ⚠️ There is one parser for each thread, and not one shared constant. A Redcarpet parser holds
  # render state and it is not thread-safe, and Middleman builds more than one page at a time.
  # @return [Redcarpet::Markdown] The parser of this thread.
  def markdown_parser
    Thread.current[:kona_markdown_parser] ||=
      Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(with_toc_data: true), **EXTENSIONS)
  end

  # Applies the SmartyPants typography to plain text.
  # @param text [String] The text to change.
  # @return [String, nil] The text after the change, or nil for a blank input.
  def smartypants(text)
    return if text.blank?
    Redcarpet::Render::SmartyPants.render(text)
  end

  # The text of a heading, with the typography and with no markup. ⚠️ SmartyPants is a typography
  # pass and not an escape: a `<` or a `&` in a title goes through as it is. Sanitize removes each
  # element and escapes the text, thus the result is safe in an element. The api has a copy.
  # @param text [String, nil] The title.
  # @return [String, nil]
  def heading_text(text)
    return if text.blank?
    Sanitize.fragment(smartypants(text))
  end
end
