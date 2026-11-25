require "nokogiri"

# The transforms of MarkupHelpers for the images of a body: the figure and its caption, the
# responsive sources, the placeholder, and the alt text.
#
# Each transform takes `html` as a String or as a parsed Nokogiri node, and it returns the same
# type. Refer to MarkupHelpers#with_nokogiri_doc.
module MarkupImageHelpers
  # Includes the common emoji blocks, the variation selectors, and the skin tone modifiers.
  EMOJI_REGEX = /([\u{1F600}-\u{1F64F}]|[\u{1F300}-\u{1F5FF}]|[\u{1F680}-\u{1F6FF}]|[\u{1F1E6}-\u{1F1FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]|[\u{1F900}-\u{1F9FF}]|[\u{1F018}-\u{1F270}])[\u{FE00}-\u{FE0F}\u{1F3FB}-\u{1F3FF}]?/

  # A group of adjacent emoji, and the spaces between them.
  EMOJI_RUN_REGEX = /((?:#{EMOJI_REGEX.source}(?:\s*#{EMOJI_REGEX.source})*))/

  # Adds the Contentful asset id and the original URL to each <img>. The subsequent image
  # transforms read them.
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
  # @param base_class [String] The base class for the figure. The content type of the asset goes
  #   at the end of it.
  def add_figure_elements_to_images(html, base_class: nil)
    with_nokogiri_doc(html) do |doc|
      doc.css("img").each do |img|
        parent = img.parent
        # ⚠️ A paragraph with more than one image gets no figure. The caption is all the other
        # content of the parent, thus the second image would go in the <figcaption> of the first,
        # and the replace of the parent would remove it while this loop still reads it.
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

  # Splits each figcaption at " | " and puts the credit at the end in a <cite>.
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
  def wrap_figcaption_emoji(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("figcaption").each do |figcaption|
        figcaption.xpath(".//text()").each do |text_node|
          text_content = text_node.content
          next unless text_content.match?(EMOJI_REGEX)

          # ⚠️ This makes nodes, and it does not parse a string as HTML. The content of a text node
          # is plain text, thus a "<" in a caption would become an element in a parse.
          document = text_node.document
          add_text = lambda do |part|
            text_node.add_previous_sibling(Nokogiri::XML::Text.new(part, document)) unless part.empty?
          end

          # `scan` with the match offsets, and not `split`: the run pattern has a group inside its
          # group, thus `split` gives each run two times.
          last = 0
          text_content.scan(EMOJI_RUN_REGEX) do
            match = Regexp.last_match
            add_text.call(text_content[last...match.begin(0)])
            span = Nokogiri::XML::Node.new("span", document)
            span["class"] = "emoji"
            span.content = match[0]
            text_node.add_previous_sibling(span)
            last = match.end(0)
          end
          add_text.call(text_content[last..])
          text_node.remove
        end
      end
    end
  end

  # Gives the LCP mark to the first image of the page that asks for it. Thus a caller can ask for
  # each image, and one image only takes the mark.
  #
  # ⚠️ The flag is an instance variable, and Middleman gives each page its own template context
  # (refer to MemoizationHelpers). Thus it covers the full page: `_body.html.erb` calls render_body
  # for the intro and for the body, and only the first image of the two gets the mark.
  # @return [Boolean] True one time for each page, and false after that.
  def claim_lcp_image
    return false if @lcp_image_claimed
    @lcp_image_claimed = true
  end

  # Adds srcset, sizes, and the true dimensions to each asset image. A <picture> element is not
  # necessary: the srcset asks for format=auto, thus Cloudflare selects the format from the
  # Accept header. This also keeps each candidate to one transformation that Cloudflare bills.
  #
  # `first_image` gives the first asset image of the PAGE a role:
  #   :priority  `fetchpriority="high"`, and the image stays lazy.
  #   :eager     the same, and `loading="eager"`.
  #
  # ⚠️ Use `:eager` only where a measurement gives that image as the LCP element, and only with a
  # `sizes` list that has no `auto`. Refer to the `home` variant of data/srcsets.yml. Most body
  # images are below the fold, thus `:priority` is correct there and `:eager` would get an image
  # that nobody sees.
  # @param widths [Array<Integer>] The candidate widths. The width of the asset is the maximum.
  # @param square [Boolean] True to cut the image to a square.
  # @param first_image [Symbol, nil] :priority, :eager, or nil for no role.
  def responsivize_images(html, widths: [ 100, 200, 300 ], sizes: "100vw", lazy: true, square: false,
                          first_image: nil)
    with_nokogiri_doc(html) do |doc|
      each_asset_image(doc) do |img, asset_id, original_url|
        width, height = get_asset_dimensions(asset_id)
        img_widths = card_widths(widths, width)

        img["loading"] = "lazy" if lazy
        if first_image && claim_lcp_image
          img["fetchpriority"] = "high"
          img["loading"] = "eager" if first_image == :eager
        end
        # An asset with no size, or with a size of 0, gets neither attribute: `width="0"` hides it.
        if width.to_i.positive? && height.to_i.positive?
          img["width"] = width
          img["height"] = square ? width : height
        end

        if gif_asset?(asset_id)
          img["src"] = cdn_image_url(original_url)
          next
        end

        img["sizes"] = sizes
        img["srcset"] = srcset(url: original_url, widths: img_widths, ratio: (1 if square), options: { fm: "auto" })

        # ⚠️ The src must be one of the candidates above, word for word: the same parameters, in the
        # same order. Refer to ImageHelpers#cover_image_tag for the reason.
        src_width = img_widths.max
        src_query = { fm: "auto", w: src_width }
        src_query.merge!({ h: src_width, fit: "cover" }) if square
        img["src"] = cdn_image_url(original_url, src_query)
      end
    end
  end

  # Sets the src of each asset image to a transformation with the given maximum width.
  def resize_images(html, width: 1000)
    with_nokogiri_doc(html) do |doc|
      each_asset_image(doc) do |img, asset_id, original_url|
        asset_width, _ = get_asset_dimensions(asset_id)

        img["src"] = if gif_asset?(asset_id)
          cdn_image_url(original_url)
        else
          cdn_image_url(original_url, { w: [ width, asset_width ].compact.min })
        end
      end
    end
  end

  # Adds the blurhash placeholder of each asset image as a CSS custom property. It also adds the
  # Stimulus attributes that remove the placeholder after the image loads.
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
  def set_alt_text(html)
    with_nokogiri_doc(html) do |doc|
      each_asset_image(doc) do |img, asset_id, _original_url|
        alt_text = get_asset_description(asset_id)
        img["alt"] = alt_text if alt_text.present?
      end
    end
  end

  private

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
end
