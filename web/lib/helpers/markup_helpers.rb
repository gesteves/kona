require "cgi"
require "nokogiri"

# Renders Markdown bodies and applies the HTML transformations that can't be expressed in
# Contentful's editor — responsive images and tables, figures, permalinks, and so on.
module MarkupHelpers
  # Covers the common emoji blocks plus variation selectors and skin tone modifiers. Hoisted out
  # of wrap_figcaption_emoji, which built both of these per text node.
  EMOJI_REGEX = /([\u{1F600}-\u{1F64F}]|[\u{1F300}-\u{1F5FF}]|[\u{1F680}-\u{1F6FF}]|[\u{1F1E6}-\u{1F1FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]|[\u{1F900}-\u{1F9FF}]|[\u{1F018}-\u{1F270}])[\u{FE00}-\u{FE0F}\u{1F3FB}-\u{1F3FF}]?/
  # A run of consecutive emoji, and the whitespace between them.
  EMOJI_RUN_REGEX = /((?:#{EMOJI_REGEX.source}(?:\s*#{EMOJI_REGEX.source})*))/

  # Renders an entry's body through the full transform pipeline.
  # @param text [String] The Markdown text to render.
  # @param image_variant [Symbol] Which responsive-images config to use.
  # @return [String] The transformed HTML.
  def render_body(text, image_variant: :entry)
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
      responsivize_images(doc, widths: srcset.widths, sizes: srcset.sizes.join(", "))
      resize_images(doc, width: srcset.widths.max)
      add_image_placeholders(doc)
      set_alt_text(doc)
      mark_affiliate_links(doc)
      responsivize_tables(doc)
      scope_table_headers(doc)
      split_table_cell_annotations(doc)
      add_heading_permalinks(doc)
      lazy_load_iframes(doc)
    end
  end

  # Renders an entry's body for the Atom feed, omitting the transforms feed readers can't use.
  # @param text [String] The Markdown text to render.
  # @return [String] The transformed HTML.
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

  # Renders a body for the home page, with square-cropped images and no degree normalization.
  # @param text [String] The Markdown text to render.
  # @return [String] The transformed HTML.
  def render_home_body(text)
    render_markup(text, degrees: false) do |doc|
      add_image_data_attributes(doc)
      add_figure_elements_to_images(doc, base_class: "home")
      set_caption_credit(doc)
      responsivize_images(doc, widths: data.srcsets.home.widths, sizes: data.srcsets.home.sizes.join(", "), square: true)
      resize_images(doc)
      add_image_placeholders(doc)
      set_alt_text(doc)
    end
  end

  # Renders a taxonomy concept's description: inline treatments only, no images or tables.
  # Affiliate marking runs last so its rel/target wins over the external-link pass.
  # @param text [String] The Markdown description.
  # @return [String] The transformed HTML.
  def render_tag_description(text)
    render_markup(text) do |doc|
      open_external_links_in_new_tabs(doc)
      add_unit_data_attributes(doc)
      mark_affiliate_links(doc)
    end
  end

  # Prepends the entry's title to its body as a bold run-in.
  # @param title [String] The entry's title.
  # @param html [String] The rendered body HTML.
  # @param hidden_from_at [Boolean] Marks the run-in aria-hidden, for pages where a
  #   visually-hidden <h1> already announces the title.
  # @return [String] The body with the run-in prepended.
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

  # Rewrites the `data-imperial` shorthand authors use in Contentful into the units Stimulus
  # controller's attributes.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
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

  # Stamps each <img> with its Contentful asset id and original URL, which the later image
  # transforms read.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
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

  # Wraps each image in a <figure>, moving whatever else shared its paragraph into a
  # <figcaption>.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @param base_class [String] Base class for the figure, suffixed with the asset's content type.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
  def add_figure_elements_to_images(html, base_class: nil)
    with_nokogiri_doc(html) do |doc|
      doc.css("img").each do |img|
        parent = img.parent
        # ⚠️ This treats "everything else in the parent" as the caption and then replaces the
        # parent outright, so two images in one paragraph would fold the second one's markup into
        # the first one's <figcaption> and detach it while this loop is still iterating over it.
        # A multi-image paragraph gets no figure rather than a corrupted one.
        next if parent.css("img").size > 1

        # Pull the image out so the caption is whatever remains in the parent, then put it back.
        img = img.remove
        caption = parent.inner_html
        parent.prepend_child(img)

        asset_id = get_asset_id(img["src"])
        content_type = get_asset_content_type(asset_id)

        # Nil for images that aren't Contentful assets, which get no content-type modifier.
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

  # Wraps each iframe in a <figure>.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @param base_class [String] Base class for the figure.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
  def add_figure_elements_to_iframes(html, base_class: nil)
    with_nokogiri_doc(html) do |doc|
      doc.css("iframe").each do |iframe|
        wrap_in_figure(doc, iframe, base_class: base_class, modifier: "iframe")
      end
    end
  end

  # Wraps each social media embed in a <figure>. Bluesky, Instagram, and Threads embeds are a
  # blockquote followed by a script.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @param base_class [String] Base class for the figure.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
  def add_figure_elements_to_embeds(html, base_class: nil)
    with_nokogiri_doc(html) do |doc|
      doc.css("blockquote + script").each do |script|
        blockquote = script.previous_element
        next unless blockquote.name == "blockquote"

        wrap_in_figure(doc, blockquote, base_class: base_class, modifier: "embed", trailing: script)
      end
    end
  end


  # Splits each figcaption on " | " and wraps the trailing credit in a <cite>.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
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

          # ⚠️ Only split a bare text node. `child.text` also reports the text *inside* an
          # element, and replacing that element with two text nodes throws its markup away — a
          # credit written as a link would silently lose the link.
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

  # Wraps runs of emoji in figcaptions with <span class="emoji">, so they can be styled.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
  def wrap_figcaption_emoji(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("figcaption").each do |figcaption|
        figcaption.xpath(".//text()").each do |text_node|
          text_content = text_node.content
          next if text_content.empty?

          if text_content.match?(EMOJI_REGEX)
            # Consecutive emoji, and the spaces between them, go in one span.
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

  # Adds srcset, sizes, and intrinsic dimensions to each asset image. No <picture> element is
  # needed: the srcset asks for format=auto, so Cloudflare negotiates the format from the Accept
  # header, which also keeps each candidate to one billable transformation.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @param widths [Array<Integer>] Candidate widths, clamped to the asset's own width.
  # @param sizes [String] The sizes attribute value.
  # @param lazy [Boolean] Whether to lazy-load.
  # @param square [Boolean] Whether to crop square.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
  def responsivize_images(html, widths: [ 100, 200, 300 ], sizes: "100vw", lazy: true, square: false)
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
        if width.present? && height.present?
          img["width"] = width
          img["height"] = square ? width : height
        end

        img["src"] = cdn_image_url(original_url)

        next if content_type == "image/gif"

        img["sizes"] = sizes
        img["srcset"] = srcset(url: original_url, widths: img_widths, square: square, options: { fm: "auto" })
      end
    end
  end

  # Points each asset image's src at a transformation capped to the given width.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @param width [Integer] The maximum width.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
  def resize_images(html, width: 1000)
    with_nokogiri_doc(html) do |doc|
      each_asset_image(doc) do |img, asset_id, original_url|
        asset_width, _ = get_asset_dimensions(asset_id)
        content_type = get_asset_content_type(asset_id)

        img["src"] = if content_type == "image/gif"
          # Untransformed, which is what keeps GIFs animated — give this a width and Cloudflare
          # flattens it to a still frame.
          cdn_image_url(original_url)
        else
          cdn_image_url(original_url, { w: [ width, asset_width ].compact.min })
        end
      end
    end
  end

  # Adds each asset image's blurhash placeholder as a CSS custom property, plus the Stimulus
  # wiring that clears it once the image loads.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
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

  # Sets each asset image's alt text from its Contentful description.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
  def set_alt_text(html)
    with_nokogiri_doc(html) do |doc|
      each_asset_image(doc) do |img, asset_id, _original_url|
        alt_text = get_asset_description(asset_id)
        img["alt"] = alt_text if alt_text.present?
      end
    end
  end

  # Wraps tables in a <wa-scroller> so they scroll horizontally on small breakpoints.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
  def responsivize_tables(html, css_class: "entry__table")
    with_nokogiri_doc(html) do |doc|
      doc.css("table").each { |table| table.wrap("<wa-scroller class=\"#{css_class}\" orientation=\"horizontal\"></wa-scroller>") }
    end
  end

  # Marks table header cells as column headers.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
  def scope_table_headers(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("thead th").each { |th| th["scope"] = "col" }
    end
  end

  # Wraps the text after a table cell's first <br> so the trailing annotation can recede behind the
  # measurement it qualifies.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @param css_class [String] The class applied to the annotation.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
  def split_table_cell_annotations(html, css_class: "entry__table-annotation")
    with_nokogiri_doc(html) do |doc|
      doc.css("table th, table td").each do |cell|
        line_break = cell.at_css("br")
        next if line_break.nil?
        annotation = Nokogiri::XML::Node.new("small", cell.document)
        annotation["class"] = css_class
        sibling = line_break.next_sibling
        while sibling
          # ⚠️ Read the next sibling first — add_child unlinks the node.
          following = sibling.next_sibling
          annotation.add_child(sibling)
          sibling = following
        end
        line_break.replace(annotation)
      end
    end
  end

  # Prepends a copy-to-clipboard permalink anchor to every h2 and h3 carrying an id.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
  def add_heading_permalinks(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("h2, h3").each do |heading|
        heading_id = heading["id"]
        next if heading_id.blank?
        heading_text = heading.text
        # ⚠️ Name the heading explicitly before nesting the permalink inside it. Accessible name
        # from content descends into the anchor and picks up *its* aria-label, so without this
        # every heading announces as "Permalink to Foo Foo". An explicit label on the heading
        # takes precedence over its contents, which keeps the link itself fully accessible
        # rather than hiding it from assistive tech to stay quiet.
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

  # Marks Amazon Associates links sponsored and opens them in a new tab.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
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

  # Adds target=_blank and rel=noopener to links pointing off-site.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
  def open_external_links_in_new_tabs(html)
    with_nokogiri_doc(html) do |doc|
      current_host = URI.parse(root_url).host
      doc.css("a").each do |a|
        href = a["href"]
        next unless href&.start_with?("http://", "https://")

        # Author-supplied links can be malformed; skip them rather than failing the build.
        link_host = URI.parse(href).host rescue next
        next if link_host.blank? || link_host == current_host

        a["rel"] = "noopener"
        a["target"] = "_blank"
      end
    end
  end

  # Renders a tag wired to the units Stimulus controller.
  # @param metric [String] The metric text.
  # @param imperial [String] The imperial text.
  # @param tag [Symbol] The element to render.
  # @return [String] An HTML tag.
  def units_tag(metric, imperial, tag = :span)
    content_tag tag.to_sym, 'data-controller': "units", 'data-units-imperial-value': imperial, 'data-units-metric-value': metric, title: "#{metric} | #{imperial}" do
      metric
    end
  end

  # Makes links to a feed copy their URL to the clipboard instead of navigating.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
  def copy_feed_links(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("a").each do |link|
        href = link["href"]
        next unless href&.end_with?("/feed.xml")

        SiteHelpers::FEED_CLIPBOARD_ATTRS.each { |name, value| link[name.to_s] = value }
      end
    end
  end

  # Marks iframes lazy-loading.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @return [String, Nokogiri::XML::Node] The processed HTML.
  def lazy_load_iframes(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("iframe").each do |iframe|
        iframe["loading"] = "lazy"
      end
    end
  end

  private

  # Wraps a node in a <figure> unless its parent already is one, then applies the figure classes.
  # @param doc [Nokogiri::XML::Document] The document the node belongs to.
  # @param node [Nokogiri::XML::Node] The node to wrap.
  # @param base_class [String, nil] The base class for the figure.
  # @param modifier [String] The figure class's modifier suffix.
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

  # The shared shape of the render_*_body pipelines: render Markdown, parse once, yield the
  # fragment to the variant's transform steps, serialize.
  # @param text [String] The Markdown text to render.
  # @param degrees [Boolean] Whether to normalize degree notation first.
  # @yield [Nokogiri::HTML::DocumentFragment] The parsed body, for in-place transforms.
  # @return [String] The transformed HTML.
  def render_markup(text, degrees: true)
    html = markdown_to_html(degrees ? fix_degrees(text) : text)
    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    yield doc
    doc.to_html
  end

  # Yields each <img> stamped by add_image_data_attributes, skipping ones with no asset.
  # @param doc [Nokogiri::XML::Node] The parsed body.
  # @yield [img, asset_id, original_url]
  def each_asset_image(doc)
    doc.css("img").each do |img|
      asset_id = img["data-asset-id"]
      next if asset_id.blank?

      yield img, asset_id, img["data-original-url"]
    end
  end

  # Lets a transform take either an HTML string or an already-parsed node, yielding a document
  # either way and returning a result of the same type as its input.
  # @param html [String, Nokogiri::XML::Node] The HTML to process.
  # @yield [Nokogiri::HTML::DocumentFragment] The document to operate on.
  # @return [String, Nokogiri::XML::Node, nil] The result, matching the input's type.
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
