require "nokogiri"

# The transforms of MarkupHelpers for an iframe and for each other embed of a body: the figure,
# the title, the size, and the lazy load.
#
# Each transform takes `html` as a String or as a parsed Nokogiri node, and it returns the same
# type. Refer to MarkupHelpers#with_nokogiri_doc.
module MarkupEmbedHelpers
  # The default title of a YouTube embed. It names the player and not the video.
  YOUTUBE_PLAYER_TITLE = "YouTube video player".freeze

  # The id of the video in a YouTube embed URL.
  YOUTUBE_EMBED_REGEX = %r{\Ahttps?://(?:www\.)?youtube(?:-nocookie)?\.com/embed/([\w-]+)}

  # A Spotify video episode embed. An audio episode embed has no `/video` segment.
  SPOTIFY_VIDEO_EMBED_REGEX = %r{\Ahttps?://open\.spotify\.com/embed/episode/[^/?#]+/video(?:[/?#]|\z)}

  # The embeds whose player is a 16:9 video.
  VIDEO_EMBED_REGEXES = [ YOUTUBE_EMBED_REGEX, SPOTIFY_VIDEO_EMBED_REGEX ].freeze

  # The inline style properties that responsivize_iframes removes.
  IFRAME_WIDTH_PROPERTIES = %w[width max-width].freeze

  # Puts each iframe in a <figure>.
  def add_figure_elements_to_iframes(html, base_class: nil)
    with_nokogiri_doc(html) do |doc|
      doc.css("iframe").each do |iframe|
        wrap_in_figure(doc, iframe, base_class: base_class, modifier: "iframe")
      end
    end
  end

  # Puts each social media embed in a <figure>. A Bluesky, Instagram, or Threads embed is a
  # blockquote and then a script.
  def add_figure_elements_to_embeds(html, base_class: nil)
    with_nokogiri_doc(html) do |doc|
      doc.css("blockquote + script").each do |script|
        blockquote = script.previous_element
        next unless blockquote.name == "blockquote"

        wrap_in_figure(doc, blockquote, base_class: base_class, modifier: "embed", trailing: script)
      end
    end
  end

  # Gives each iframe with no title an accessible name. It keeps a title that the author wrote.
  #
  # ⚠️ A person writes each embed by hand, as raw HTML in the Contentful body, and can omit the
  # `title`. A screen reader announces a frame with no name as "frame" only, and that is a serious
  # WCAG failure.
  def set_iframe_titles(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("iframe").each do |iframe|
        next if iframe["title"].present?
        iframe["title"] = iframe_title(iframe)
      end
    end
  end

  # Removes the width rules from the inline style of each iframe. Thus the body stylesheet gives
  # each embed the full width of the text column. A video embed also loses its width and height
  # attributes, thus the stylesheet gives it a 16:9 ratio at each width.
  #
  # ⚠️ An embed code can have its own maximum width, for example `max-width:640px` from Apple
  # Podcasts. An inline style has more importance than the stylesheet.
  # ⚠️ Keep the height of each other embed. An audio player has a fixed height, and a ratio would
  # make it too short on a phone.
  def responsivize_iframes(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("iframe").each do |iframe|
        if VIDEO_EMBED_REGEXES.any? { |regex| iframe["src"].to_s.match?(regex) }
          iframe.remove_attribute("width")
          iframe.remove_attribute("height")
        end
        next if iframe["style"].nil?

        declarations = iframe["style"].split(";").map(&:strip).reject do |declaration|
          declaration.blank? || IFRAME_WIDTH_PROPERTIES.include?(declaration.split(":", 2).first.strip.downcase)
        end
        if declarations.empty?
          iframe.remove_attribute("style")
        else
          iframe["style"] = declarations.join(";")
        end
      end
    end
  end

  # Marks each iframe to load only when it is necessary.
  def lazy_load_iframes(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("iframe").each do |iframe|
        iframe["loading"] = "lazy"
      end
    end
  end

  # The name for an iframe with no title: the caption of its figure, or the host that it embeds.
  def iframe_title(iframe)
    caption = iframe.parent&.at_css("figcaption")&.text.to_s.strip
    return caption if caption.present?

    host = begin
      URI.parse(iframe["src"].to_s).host
    rescue URI::InvalidURIError
      nil
    end
    host.present? ? "Embedded content from #{host.sub(/\Awww\./, '')}" : "Embedded content"
  end

  private

  # Puts a node in a <figure>, but not if its parent is already a <figure>. Then it adds the
  # figure classes.
  #
  # ⚠️ A node that is alone in a paragraph replaces that paragraph, and the other content of the
  # paragraph goes into a <figcaption>. A <figure> inside a <p> is not valid HTML: the browser
  # closes the paragraph at the figure, and the text after it becomes a sibling. A paragraph with
  # more than one such node keeps its figures in place.
  # @param modifier [String] The modifier at the end of the figure class.
  # @param trailing [Nokogiri::XML::Node, nil] A sibling to move into the figure after the node.
  def wrap_in_figure(doc, node, base_class:, modifier:, trailing: nil)
    parent = node.parent

    if parent.name != "figure"
      figure = Nokogiri::XML::Node.new("figure", doc)
      caption = nil

      if parent.name == "p" && parent.css(node.name).size == 1
        node.remove
        trailing&.remove
        caption = parent.inner_html.strip
        parent.replace(figure)
      else
        node.replace(figure)
      end

      figure.add_child(node)
      figure.add_child(trailing) if trailing
      figure.add_child("<figcaption>#{caption}</figcaption>") if caption.present?
      parent = figure
    end

    parent["class"] = "#{base_class}__figure #{base_class}__figure--#{modifier}" if base_class.present?
  end
end
