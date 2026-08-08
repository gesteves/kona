require "redcarpet"

module MarkdownHelper
  # The Markdown extensions used everywhere the app parses Markdown (here and in the
  # standard.site sync's fingerprint-stable plain-text stripping).
  EXTENSIONS = {
    fenced_code_blocks: true, disable_indented_code_blocks: true, tables: true, autolink: true, superscript: true
  }.freeze

  # Converts Markdown to HTML with SmartyPants typography. Used to render the weather
  # summary (which emits **bold** for the location and race-day note).
  def markdown_to_html(text)
    return if text.blank?
    Redcarpet::Render::SmartyPants.render(markdown_parser.render(text))
  end

  # ⚠️ Per-thread, not a constant: Redcarpet parsers hold render state and aren't thread-safe,
  # and ParallelUpstreams fans widget rendering out across threads.
  # @return [Redcarpet::Markdown] The reused parser for this thread.
  def markdown_parser
    Thread.current[:kona_markdown_parser] ||=
      Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(with_toc_data: true), **EXTENSIONS)
  end

  # Strips a Markdown string to plain text (tags removed, entities decoded) — ported from the
  # static site's `sanitize` helper. Renders to HTML first so Markdown syntax (links, emphasis,
  # lists) becomes words rather than literal markup.
  # @param text [String, nil]
  # @return [String, nil]
  def markdown_to_plain_text(text)
    return if text.blank?
    html = markdown_to_html(text)
    return if html.blank?
    HTMLEntities.new.decode(Sanitize.fragment(html).strip)
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
