require "redcarpet"

module MarkdownHelper
  # The Markdown extensions for each Markdown parse in the app: here, and in the plain-text code of
  # the standard.site sync, whose output must not change between two runs.
  EXTENSIONS = {
    fenced_code_blocks: true, disable_indented_code_blocks: true, tables: true, autolink: true, superscript: true
  }.freeze

  # Changes Markdown into HTML, with the SmartyPants typography. The weather summary uses it, and
  # that summary writes **bold** for the location and for the race-day note.
  def markdown_to_html(text)
    return if text.blank?
    Redcarpet::Render::SmartyPants.render(markdown_parser.render(text))
  end

  # ⚠️ There is one parser for each thread, and not one constant. A Redcarpet parser holds render
  # state and it is not thread-safe, and ParallelUpstreams renders a widget across more than one
  # thread.
  # @return [Redcarpet::Markdown] The parser of this thread.
  def markdown_parser
    Thread.current[:kona_markdown_parser] ||=
      Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(with_toc_data: true), **EXTENSIONS)
  end

  # Changes a Markdown string into plain text: it removes the tags and decodes the entities. This
  # code comes from the `sanitize` helper of the static site. It renders the HTML first, thus the
  # Markdown syntax for a link, for emphasis, and for a list becomes words and not markup.
  # @param text [String, nil]
  # @return [String, nil]
  def markdown_to_plain_text(text)
    return if text.blank?
    html = markdown_to_html(text)
    return if html.blank?
    HTMLEntities.new.decode(Sanitize.fragment(html).strip)
  end

  # Applies the SmartyPants typography, that is, curly quotation marks and em dashes, to a plain
  # string. It renders no Markdown block. The app uses it for text such as an event title.
  # @param text [String, nil]
  # @return [String, nil]
  def smartypants(text)
    return if text.blank?
    Redcarpet::Render::SmartyPants.render(text)
  end
end
