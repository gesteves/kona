require "nokogiri"
require "uri"

# Renders a Contentful body as portable Markdown, for a reader on another site. The Markdown
# document of each post and the AboutSpec document of the about page both use it.
module MarkdownDocumentHelpers
  # Renders a body as portable Markdown, for a reader on another site. It uses the feed transforms,
  # then changes each construct with no Markdown form into plain Markdown.
  #
  # ⚠️ A construct that normalize_for_markdown does not know goes out as its text only. Add a step
  # there for each new kind of markup in a body.
  # @param text [String] The Markdown text from Contentful.
  # @param base_url [String] The URL of the page. Each relative link resolves against it.
  # @return [String, nil] The Markdown, or nil for a blank input.
  def render_markdown_body(text, base_url:)
    return if text.blank?

    html = render_markup(text) do |doc|
      add_image_data_attributes(doc)
      add_figure_elements_to_images(doc)
      add_figure_elements_to_iframes(doc)
      add_figure_elements_to_embeds(doc)
      set_caption_credit(doc)
      resize_images(doc, width: data.srcsets.entry.widths.max)
      set_alt_text(doc)
      set_iframe_titles(doc)
      normalize_for_markdown(doc, base_url: base_url)
    end
    html_to_markdown(html)
  end

  private

  # Changes the HTML of the feed transforms into HTML that has a Markdown form.
  # @param doc [Nokogiri::HTML::DocumentFragment] The parsed body.
  # @param base_url [String] The URL that each relative link resolves against.
  # @return [void]
  def normalize_for_markdown(doc, base_url:)
    doc.css("script, style").remove
    doc.css("figure").each { |figure| unwrap_figure(doc, figure) }
    doc.css("iframe").each { |iframe| iframe.replace(iframe_link(doc, iframe)) }
    doc.css("cite").each { |cite| cite.name = "em" }
    doc.css("[data-imperial]").each do |element|
      element.replace(Nokogiri::XML::Text.new("#{element.text} (#{element['data-imperial']})", doc))
    end
    doc.css("a[href]").each { |a| a["href"] = absolute_url(base_url, a["href"]) }
    doc.css("img[src]").each { |img| img["src"] = absolute_url(base_url, img["src"]) }
  end

  # Replaces a <figure> with its content and a paragraph for its caption. An image goes in a
  # paragraph, and an iframe becomes a link.
  # @param doc [Nokogiri::HTML::DocumentFragment] The parsed body.
  # @param figure [Nokogiri::XML::Node] The figure.
  # @return [void]
  def unwrap_figure(doc, figure)
    figcaption = figure.at_css("figcaption")&.remove
    nodes = figure.element_children.map do |child|
      case child.name
      when "img" then wrap_node(doc, "p", child)
      when "iframe" then wrap_node(doc, "p", iframe_link(doc, child))
      else child
      end
    end
    nodes << caption_paragraph(figcaption) if figcaption&.text.present?
    nodes.each { |node| figure.add_previous_sibling(node) }
    figure.remove
  end

  # Changes a figcaption into a paragraph. Its credit becomes plain text after the caption, with the
  # " | " separator that the author wrote.
  # @param figcaption [Nokogiri::XML::Node] The figcaption.
  # @return [Nokogiri::XML::Node] The paragraph.
  def caption_paragraph(figcaption)
    credit = figcaption.at_xpath("./cite")
    if credit
      # set_caption_credit already put a space before the credit.
      caption = credit.xpath("preceding-sibling::node()").map(&:text).join.strip
      credit.add_previous_sibling(Nokogiri::XML::Text.new("| ", figcaption.document)) if caption.present?
      credit.replace(credit.children)
    end
    figcaption.name = "p"
    figcaption
  end

  # A link to the content of an iframe. A YouTube embed links to the watch page of its video.
  # @param doc [Nokogiri::HTML::DocumentFragment] The parsed body.
  # @param iframe [Nokogiri::XML::Node] The iframe.
  # @return [Nokogiri::XML::Node] The link.
  def iframe_link(doc, iframe)
    src = iframe["src"].to_s
    youtube_id = src[MarkupHelpers::YOUTUBE_EMBED_REGEX, 1]
    title = iframe["title"].presence || iframe_title(iframe)

    a = Nokogiri::XML::Node.new("a", doc)
    if youtube_id
      a["href"] = "https://www.youtube.com/watch?v=#{youtube_id}"
      a.content = title == MarkupHelpers::YOUTUBE_PLAYER_TITLE ? "Watch on YouTube" : title
    else
      a["href"] = src
      a.content = title
    end
    a
  end

  # @param doc [Nokogiri::HTML::DocumentFragment] The parsed body.
  # @param name [String] The name of the new element.
  # @param node [Nokogiri::XML::Node] The node to put in it.
  # @return [Nokogiri::XML::Node] The new element.
  def wrap_node(doc, name, node)
    wrapper = Nokogiri::XML::Node.new(name, doc)
    wrapper.add_child(node)
    wrapper
  end

  # Resolves a URL against the URL of the page. A URL with an incorrect shape stays as it is.
  # @param base_url [String] The URL of the page.
  # @param url [String] The URL to resolve.
  # @return [String] The absolute URL.
  def absolute_url(base_url, url)
    URI.join(base_url, url).to_s
  rescue URI::Error
    url
  end
end
