require "cgi"
require "nokogiri"

# Renders Markdown bodies and does the HTML transformations that the Contentful editor cannot
# do: responsive images and tables, figures, permalinks, and more.
module MarkupHelpers
  # Includes the common emoji blocks, the variation selectors, and the skin tone modifiers. It is
  # a constant, thus wrap_figcaption_emoji does not make it again for each text node.
  EMOJI_REGEX = /([\u{1F600}-\u{1F64F}]|[\u{1F300}-\u{1F5FF}]|[\u{1F680}-\u{1F6FF}]|[\u{1F1E6}-\u{1F1FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]|[\u{1F900}-\u{1F9FF}]|[\u{1F018}-\u{1F270}])[\u{FE00}-\u{FE0F}\u{1F3FB}-\u{1F3FF}]?/
  # A group of adjacent emoji, and the spaces between them.
  EMOJI_RUN_REGEX = /((?:#{EMOJI_REGEX.source}(?:\s*#{EMOJI_REGEX.source})*))/

  # Renders the body of an entry through the full transform pipeline.
  # @param text [String] The Markdown text to render.
  # @param image_variant [Symbol] The responsive-images configuration to use.
  # @return [String] The HTML after the transforms.
  def render_body(text, image_variant: :entry, first_image: nil)
    srcset = data.srcsets[image_variant]
    render_markup(text) do |doc|
      open_external_links_in_new_tabs(doc)
      copy_feed_links(doc)
      add_unit_data_attributes(doc)
      add_image_data_attributes(doc)
      add_figure_elements_to_images(doc, base_class: "entry")
      add_figure_elements_to_iframes(doc, base_class: "entry")
      add_figure_elements_to_embeds(doc, base_class: "entry")
      set_caption_credit(doc)
      wrap_figcaption_emoji(doc)
      responsivize_images(doc, widths: srcset.widths, sizes: srcset.sizes.join(", "),
                          first_image: first_image)
      add_image_placeholders(doc)
      set_alt_text(doc)
      mark_affiliate_links(doc)
      responsivize_tables(doc)
      scope_table_headers(doc)
      split_table_cell_annotations(doc)
      add_heading_permalinks(doc)
      set_iframe_titles(doc)
      lazy_load_iframes(doc)
    end
  end

  # Renders the body of an entry for the Atom feed. It does not do the transforms that a feed
  # reader cannot use.
  # @param text [String] The Markdown text to render.
  # @return [String] The HTML after the transforms.
  def render_feed_body(text)
    render_markup(text) do |doc|
      add_image_data_attributes(doc)
      add_figure_elements_to_images(doc)
      add_figure_elements_to_iframes(doc)
      add_figure_elements_to_embeds(doc)
      set_caption_credit(doc)
      resize_images(doc, width: data.srcsets.entry.widths.max)
      set_alt_text(doc)
      mark_affiliate_links(doc)
    end
  end

  # Renders a body for the home page, with square images and no change to the degree notation.
  # @param text [String] The Markdown text to render.
  # @return [String] The HTML after the transforms.
  def render_home_body(text)
    render_markup(text, degrees: false) do |doc|
      add_image_data_attributes(doc)
      add_figure_elements_to_images(doc, base_class: "home")
      set_caption_credit(doc)
      # ⚠️ `first_image: :eager` is correct HERE and almost nowhere else. A measurement of the
      # home page gave this image as the LCP element: it is above the fold, and each other
      # candidate is text. The `home` variant has no `auto` in its `sizes` for the same reason:
      # `auto` is valid on a lazy image only. Refer to data/srcsets.yml.
      responsivize_images(doc, widths: data.srcsets.home.widths, sizes: data.srcsets.home.sizes.join(", "),
                          square: true, first_image: :eager)
      add_image_placeholders(doc)
      set_alt_text(doc)
    end
  end

  # Renders the description of a taxonomy concept: inline treatments only, no images and no
  # tables. The affiliate step runs last, thus its rel and target replace those from the
  # external-link step.
  # @param text [String] The Markdown description.
  # @return [String] The HTML after the transforms.
  def render_tag_description(text)
    render_markup(text) do |doc|
      open_external_links_in_new_tabs(doc)
      add_unit_data_attributes(doc)
      mark_affiliate_links(doc)
    end
  end

  # Adds the title of an entry to the start of its body, as a bold run-in.
  # @param title [String] The title of the entry.
  # @param html [String] The rendered body HTML.
  # @param hidden_from_at [Boolean] Marks the run-in aria-hidden, for a page where a
  #   visually-hidden <h1> already speaks the title.
  # @return [String] The body, with the run-in at the start.
  def prepend_title(title, html, hidden_from_at: false)
    doc = Nokogiri::HTML::DocumentFragment.parse(html)

    aria = hidden_from_at ? ' aria-hidden="true"' : ""
    if title.match?(/[a-zA-Z0-9]$/)
      formatted_title = "<b#{aria}>#{title}.</b>"
    else
      formatted_title = "<b#{aria}>#{title}</b>"
    end

    if doc.children.first.name == "p"
      first_p = doc.children.first
      first_p.inner_html = "#{formatted_title} #{first_p.inner_html}"
    else
      new_p = Nokogiri::HTML::DocumentFragment.parse("<p>#{formatted_title}</p>").children.first
      doc.children.first.add_previous_sibling(new_p)
    end

    doc.to_html
  end

  # Changes the `data-imperial` shorthand from Contentful into the attributes of the units
  # Stimulus controller.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  # @example
  #   add_unit_data_attributes('<span data-imperial="6.21 mi">10 km</span>')
  #   # => '<span data-units-imperial-value="6.21 mi" data-units-metric-value="10 km" data-controller="units">10 km</span>'
  def add_unit_data_attributes(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("[data-imperial]").each do |element|
        imperial_value = element["data-imperial"]
        metric_value = element.text
        new_element = units_tag(metric_value, imperial_value, element.name.to_sym)
        element.replace(Nokogiri::HTML::DocumentFragment.parse(new_element))
      end
    end
  end

  # Adds the Contentful asset id and the original URL to each <img>. The subsequent image
  # transforms read them.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def add_image_data_attributes(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("img").each do |img|
        original_url = img["src"]
        asset_id = get_asset_id(original_url)
        img["data-asset-id"] = asset_id
        img["data-original-url"] = original_url
      end
    end
  end

  # Puts each image in a <figure>. The other content of the same paragraph goes into a
  # <figcaption>.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @param base_class [String] The base class for the figure. The content type of the asset goes
  #   at the end of it.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def add_figure_elements_to_images(html, base_class: nil)
    with_nokogiri_doc(html) do |doc|
      doc.css("img").each do |img|
        parent = img.parent
        # ⚠️ This uses "all the other content of the parent" as the caption, then replaces the
        # parent. Thus two images in one paragraph would put the markup of the second image in
        # the <figcaption> of the first, and remove it while this loop still reads it. A
        # paragraph with more than one image gets no figure, and not a bad one.
        next if parent.css("img").size > 1

        # Remove the image, thus the caption is the remainder of the parent. Then put it back.
        img = img.remove
        caption = parent.inner_html
        parent.prepend_child(img)

        asset_id = get_asset_id(img["src"])
        content_type = get_asset_content_type(asset_id)

        # Nil for an image that is not a Contentful asset. It then gets no content-type modifier.
        figure = if base_class.present?
          modifier = content_type&.split("/")&.last
          figure_class = [ "#{base_class}__figure", ("#{base_class}__figure--#{modifier}" if modifier) ].compact.join(" ")
          "<figure class=\"#{figure_class}\"></figure>"
        else
          "<figure></figure>"
        end
        img.wrap(figure)
        img.add_next_sibling("<figcaption>#{caption}</figcaption>") if caption.present?
        parent.replace(img.parent)
      end
    end
  end

  # Puts each iframe in a <figure>.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @param base_class [String] The base class for the figure.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def add_figure_elements_to_iframes(html, base_class: nil)
    with_nokogiri_doc(html) do |doc|
      doc.css("iframe").each do |iframe|
        wrap_in_figure(doc, iframe, base_class: base_class, modifier: "iframe")
      end
    end
  end

  # Puts each social media embed in a <figure>. A Bluesky, Instagram, or Threads embed is a
  # blockquote and then a script.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @param base_class [String] The base class for the figure.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def add_figure_elements_to_embeds(html, base_class: nil)
    with_nokogiri_doc(html) do |doc|
      doc.css("blockquote + script").each do |script|
        blockquote = script.previous_element
        next unless blockquote.name == "blockquote"

        wrap_in_figure(doc, blockquote, base_class: base_class, modifier: "embed", trailing: script)
      end
    end
  end


  # Splits each figcaption at " | " and puts the credit at the end in a <cite>.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def set_caption_credit(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("figcaption").each do |figcaption|
        children = figcaption.children
        found_separator = false
        caption_nodes = []
        credit_nodes = []

        children.each do |child|
          if found_separator
            credit_nodes << child
            next
          end

          # ⚠️ Split only a bare text node. `child.text` also gives the text *in* an element. If
          # you replace that element with two text nodes, its markup goes away, and a credit
          # written as a link loses the link.
          if child.text? && child.text.include?(" | ")
            before, after = child.text.split(" | ", 2)
            caption_nodes << Nokogiri::XML::Text.new(before, doc)
            credit_nodes << Nokogiri::XML::Text.new(after, doc)
            found_separator = true
          else
            caption_nodes << child
          end
        end

        if found_separator
          figcaption.children.remove
          caption_nodes.each { |node| figcaption.add_child(node) }
          cite = Nokogiri::XML::Node.new("cite", doc)
          credit_nodes.each { |node| cite.add_child(node) }
          figcaption.add_child(Nokogiri::XML::Text.new(" ", doc)) unless credit_nodes.empty?
          figcaption.add_child(cite)
        end
      end
    end
  end

  # Puts each group of emoji in a figcaption in a <span class="emoji">, thus CSS can style them.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def wrap_figcaption_emoji(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("figcaption").each do |figcaption|
        figcaption.xpath(".//text()").each do |text_node|
          text_content = text_node.content
          next if text_content.empty?

          if text_content.match?(EMOJI_REGEX)
            # Adjacent emoji, and the spaces between them, go in one span.
            new_content = text_content.gsub(EMOJI_RUN_REGEX) do |match|
              "<span class=\"emoji\">#{match}</span>"
            end

            new_fragment = Nokogiri::HTML::DocumentFragment.parse(new_content)
            text_node.replace(new_fragment)
          end
        end
      end
    end
  end

  # Adds srcset, sizes, and the true dimensions to each asset image. A <picture> element is not
  # necessary: the srcset asks for format=auto, thus Cloudflare selects the format from the
  # Accept header. This also keeps each candidate to one transformation that Cloudflare bills.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @param widths [Array<Integer>] The candidate widths. The width of the asset is the maximum.
  # @param sizes [String] The value of the sizes attribute.
  # @param lazy [Boolean] True to load the image only when it is necessary.
  # @param square [Boolean] True to cut the image to a square.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  # Marks the first asset image of the page as the probable LCP element.
  #
  # ⚠️ The flag is an instance variable, thus it covers the full page: `_body.html.erb` calls
  # render_body two times, for the intro and for the body, and only the first image of the two gets
  # the mark. Middleman gives each page its own template context. Refer to MemoizationHelpers.
  # @return [Boolean] True one time for each page, and false after that.
  def claim_lcp_image
    return false if @lcp_image_claimed
    @lcp_image_claimed = true
  end

  # `first_image` gives the first asset image of the PAGE a role:
  #   :priority  `fetchpriority="high"`, and the image stays lazy.
  #   :eager     the same, and `loading="eager"`.
  #
  # ⚠️ Use `:eager` only where a measurement gives that image as the LCP element, and only with a
  # `sizes` list that has no `auto`. `auto` is valid on a lazy image only, and a browser ignores it
  # on an eager image. Today the home page hero is the one such image. Most body images are below
  # the fold, thus `:priority` is correct there and `:eager` would get an image that nobody sees.
  def responsivize_images(html, widths: [ 100, 200, 300 ], sizes: "100vw", lazy: true, square: false,
                          first_image: nil)
    with_nokogiri_doc(html) do |doc|
      each_asset_image(doc) do |img, asset_id, original_url|
        width, height = get_asset_dimensions(asset_id)
        content_type = get_asset_content_type(asset_id)

        img_widths = widths.dup
        if width.present?
          img_widths << width if width < img_widths.max
          img_widths = img_widths.reject { |w| w > width }
        end
        img_widths = img_widths.uniq.sort

        img["loading"] = "lazy" if lazy
        if first_image && claim_lcp_image
          img["fetchpriority"] = "high"
          img["loading"] = "eager" if first_image == :eager
        end
        if width.present? && height.present?
          img["width"] = width
          img["height"] = square ? width : height
        end

        # No transformation for a GIF, thus it keeps its animation. A width would make one static
        # frame from it. resize_images has the same rule.
        if content_type == "image/gif"
          img["src"] = cdn_image_url(original_url)
          next
        end

        img["sizes"] = sizes
        img["srcset"] = srcset(url: original_url, widths: img_widths, ratio: (1 if square), options: { fm: "auto" })

        # ⚠️ The src must be one of the candidates above, word for word: the same parameters, in the
        # same order. Cloudflare renders and bills one transformation for each different URL, thus a
        # src that only looks the same is a second render of each image that no browser uses.
        src_width = img_widths.max
        src_query = { fm: "auto", w: src_width }
        src_query.merge!({ h: src_width, fit: "cover" }) if square
        img["src"] = cdn_image_url(original_url, src_query)
      end
    end
  end

  # Sets the src of each asset image to a transformation with the given maximum width.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @param width [Integer] The maximum width.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def resize_images(html, width: 1000)
    with_nokogiri_doc(html) do |doc|
      each_asset_image(doc) do |img, asset_id, original_url|
        asset_width, _ = get_asset_dimensions(asset_id)
        content_type = get_asset_content_type(asset_id)

        img["src"] = if content_type == "image/gif"
          # No transformation, thus a GIF keeps its animation. If you give this a width,
          # Cloudflare makes one static frame from it.
          cdn_image_url(original_url)
        else
          cdn_image_url(original_url, { w: [ width, asset_width ].compact.min })
        end
      end
    end
  end

  # Adds the blurhash placeholder of each asset image as a CSS custom property. It also adds the
  # Stimulus attributes that remove the placeholder after the image loads.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def add_image_placeholders(html)
    with_nokogiri_doc(html) do |doc|
      each_asset_image(doc) do |img, asset_id, _original_url|
        blurhash_svg_data_uri = blurhash_svg_data_uri(asset_id)
        img["style"] = "--placeholder:url('#{blurhash_svg_data_uri}');" unless blurhash_svg_data_uri.blank?
        img["class"] = [ img["class"], "placeholder" ].compact.join(" ")
        img["data-controller"] = "image-placeholder"
        img["data-action"] = "load->image-placeholder#removePlaceholder error->image-placeholder#removePlaceholder"
      end
    end
  end

  # Sets the alt text of each asset image from its Contentful description.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def set_alt_text(html)
    with_nokogiri_doc(html) do |doc|
      each_asset_image(doc) do |img, asset_id, _original_url|
        alt_text = get_asset_description(asset_id)
        img["alt"] = alt_text if alt_text.present?
      end
    end
  end

  # Puts each table in a <wa-scroller>, thus it scrolls horizontally at a small breakpoint.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def responsivize_tables(html, css_class: "entry__table")
    with_nokogiri_doc(html) do |doc|
      doc.css("table").each { |table| table.wrap("<wa-scroller class=\"#{css_class}\" orientation=\"horizontal\"></wa-scroller>") }
    end
  end

  # Marks table header cells as column headers.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def scope_table_headers(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("thead th").each { |th| th["scope"] = "col" }
    end
  end

  # Puts the text after the first <br> of a table cell in an element. Thus the annotation at the
  # end can be less prominent than the measurement that it describes.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @param css_class [String] The class for the annotation.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def split_table_cell_annotations(html, css_class: "entry__table-annotation")
    with_nokogiri_doc(html) do |doc|
      doc.css("table th, table td").each do |cell|
        line_break = cell.at_css("br")
        next if line_break.nil?
        annotation = Nokogiri::XML::Node.new("small", cell.document)
        annotation["class"] = css_class
        sibling = line_break.next_sibling
        while sibling
          # ⚠️ Read the next sibling first, because add_child removes the node from its parent.
          following = sibling.next_sibling
          annotation.add_child(sibling)
          sibling = following
        end
        line_break.replace(annotation)
      end
    end
  end

  # Adds a copy-to-clipboard permalink anchor at the start of each h2 and h3 that has an id.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def add_heading_permalinks(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("h2, h3").each do |heading|
        heading_id = heading["id"]
        next if heading_id.blank?
        heading_text = heading.text
        # ⚠️ Give the heading a name before you put the permalink in it. The accessible name from
        # content goes into the anchor and reads *its* aria-label. Without this name, each
        # heading speaks as "Permalink to Foo Foo". A name on the heading has more importance
        # than its content. Thus the link stays fully accessible, and it is not hidden from
        # assistive technology.
        heading["aria-label"] = heading_text
        label = CGI.escapeHTML("Permalink to #{heading_text}")
        permalink = <<~HTML
          <a href="##{heading_id}" class="entry__heading-permalink" aria-label="#{label}" title="#{label}" data-controller="clipboard" data-clipboard-hidden-class="entry__heading-permalink-icon--hidden" data-clipboard-success-message-value="A link to this section has been copied to your clipboard." data-action="click->clipboard#copy">
            <span data-clipboard-target="link" class="entry__heading-permalink-icon">
              #{icon_svg("classic", "solid", "link-simple")}
            </span>
            <span data-clipboard-target="check" class="entry__heading-permalink-icon entry__heading-permalink-icon--hidden">
              #{icon_svg("classic", "solid", "check")}
            </span>
          </a>
        HTML
        heading.children.before(Nokogiri::HTML::DocumentFragment.parse(permalink))
      end
    end
  end

  # Marks each Amazon Associates link as sponsored and opens it in a new tab.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def mark_affiliate_links(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("a").each do |a|
        if amazon_associates_link?(a["href"])
          a["rel"] = "sponsored nofollow noopener"
          a["target"] = "_blank"
        end
      end
    end
  end

  # Adds target=_blank and rel=noopener to each link to a different site.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def open_external_links_in_new_tabs(html)
    with_nokogiri_doc(html) do |doc|
      current_host = URI.parse(root_url).host
      doc.css("a").each do |a|
        href = a["href"]
        next unless href&.start_with?("http://", "https://")

        # A link from the author can be incorrect. Ignore such a link and do not stop the build.
        link_host = URI.parse(href).host rescue next
        next if link_host.blank? || link_host == current_host

        a["rel"] = "noopener"
        a["target"] = "_blank"
      end
    end
  end

  # Renders a tag that is connected to the units Stimulus controller.
  # @param metric [String] The metric text.
  # @param imperial [String] The imperial text.
  # @param tag [Symbol] The element to render.
  # @return [String] An HTML tag.
  def units_tag(metric, imperial, tag = :span)
    content_tag tag.to_sym, 'data-controller': "units", 'data-units-imperial-value': imperial, 'data-units-metric-value': metric, title: "#{metric} | #{imperial}" do
      metric
    end
  end

  # Makes each link to a feed copy its URL to the clipboard. The link does not navigate.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def copy_feed_links(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("a").each do |link|
        href = link["href"]
        next unless href&.end_with?("/feed.xml")

        SiteHelpers::FEED_CLIPBOARD_ATTRS.each { |name, value| link[name.to_s] = value }
      end
    end
  end

  # Gives each iframe an accessible name.
  #
  # ⚠️ A frame with no name is a serious WCAG failure: a screen reader announces only "frame". An
  # embed comes from raw HTML in the Contentful body, thus a person writes it by hand and a `title`
  # is easy to forget. This step is the one thing between that and a page with no name for its
  # player. It never replaces a title that the author wrote.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def set_iframe_titles(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("iframe").each do |iframe|
        next if iframe["title"].present?
        iframe["title"] = iframe_title(iframe)
      end
    end
  end

  # Marks each iframe to load only when it is necessary.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @return [String, Nokogiri::XML::Node] The HTML after the change.
  def lazy_load_iframes(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("iframe").each do |iframe|
        iframe["loading"] = "lazy"
      end
    end
  end

  private

  # The name for an iframe with no title: the caption of its figure, or the host that it embeds.
  # @param iframe [Nokogiri::XML::Node] The iframe.
  # @return [String] The title.
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

  # Puts a node in a <figure>, but not if its parent is already a <figure>. Then it adds the
  # figure classes.
  # @param doc [Nokogiri::XML::Document] The document that contains the node.
  # @param node [Nokogiri::XML::Node] The node to put in the figure.
  # @param base_class [String, nil] The base class for the figure.
  # @param modifier [String] The modifier at the end of the figure class.
  # @param trailing [Nokogiri::XML::Node, nil] A sibling to move into the figure after the node.
  # @return [void]
  def wrap_in_figure(doc, node, base_class:, modifier:, trailing: nil)
    parent = node.parent

    if parent.name != "figure"
      figure = Nokogiri::XML::Node.new("figure", doc)
      node.replace(figure)
      figure.add_child(node)
      figure.add_child(trailing) if trailing
      parent = figure
    end

    parent["class"] = "#{base_class}__figure #{base_class}__figure--#{modifier}" if base_class.present?
  end

  # The shared shape of the render_*_body pipelines: render the Markdown, parse it one time, give
  # the fragment to the transform steps of the variant, then serialize it.
  # @param text [String] The Markdown text to render.
  # @param degrees [Boolean] True to correct the degree notation first.
  # @yield [Nokogiri::HTML::DocumentFragment] The parsed body, for transforms in place.
  # @return [String] The HTML after the transforms.
  def render_markup(text, degrees: true)
    html = markdown_to_html(degrees ? fix_degrees(text) : text)
    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    yield doc
    doc.to_html
  end

  # Gives each <img> that add_image_data_attributes marked. It does not give an <img> that has
  # no asset.
  # @param doc [Nokogiri::XML::Node] The parsed body.
  # @yield [img, asset_id, original_url]
  def each_asset_image(doc)
    doc.css("img").each do |img|
      asset_id = img["data-asset-id"]
      next if asset_id.blank?

      yield img, asset_id, img["data-original-url"]
    end
  end

  # Lets a transform take an HTML string or a parsed node. It gives a document for both, and
  # returns a result of the same type as the input.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @yield [Nokogiri::HTML::DocumentFragment] The document to change.
  # @return [String, Nokogiri::XML::Node, nil] The result, of the same type as the input.
  def with_nokogiri_doc(html)
    if html.is_a?(Nokogiri::XML::Node)
      yield html
      html
    elsif html.present?
      doc = Nokogiri::HTML::DocumentFragment.parse(html)
      yield doc
      doc.to_html
    end
  end
end
