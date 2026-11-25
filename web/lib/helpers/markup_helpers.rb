require "cgi"
require "htmlentities"
require "nokogiri"

# Renders Markdown bodies and does the HTML transformations that the Contentful editor cannot
# do: responsive images and tables, figures, permalinks, and more.
#
# Each transform takes `html` as a String or as a parsed Nokogiri node, and it returns the same
# type. Refer to #with_nokogiri_doc.
module MarkupHelpers
  # Includes the common emoji blocks, the variation selectors, and the skin tone modifiers.
  EMOJI_REGEX = /([\u{1F600}-\u{1F64F}]|[\u{1F300}-\u{1F5FF}]|[\u{1F680}-\u{1F6FF}]|[\u{1F1E6}-\u{1F1FF}]|[\u{2600}-\u{26FF}]|[\u{2700}-\u{27BF}]|[\u{1F900}-\u{1F9FF}]|[\u{1F018}-\u{1F270}])[\u{FE00}-\u{FE0F}\u{1F3FB}-\u{1F3FF}]?/
  # A group of adjacent emoji, and the spaces between them.
  EMOJI_RUN_REGEX = /((?:#{EMOJI_REGEX.source}(?:\s*#{EMOJI_REGEX.source})*))/
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
  # The analytics section of a link to an article in the text of an entry.
  ARTICLE_BODY_SECTION = "Article Body".freeze
  # ⚠️ The permalink shape of a published article. It must match Contentful#set_article_path.
  ARTICLE_PATH_REGEX = %r{\A/\d{4}/\d{2}/\d{2}/[^/]+/?\z}

  # Renders the body of an entry through the full transform pipeline.
  #
  # ⚠️ With no `first_image`, the code keeps the result by text, variant, and link section: the
  # blog index and the tag archives render the same intro many times. With a `first_image`, the
  # result names the LCP image of THIS page, thus the code renders it each time.
  # @param text [String] The Markdown text to render.
  # @param image_variant [Symbol] The name of a variant in data/srcsets.yml.
  # @param first_image [Symbol, nil] Refer to #responsivize_images.
  # @param link_section [String, nil] The analytics section of each link to an article. With nil,
  #   the links get no analytics classes.
  # @return [String] The HTML after the transforms.
  def render_body(text, image_variant: :entry, first_image: nil, link_section: nil)
    if first_image
      return render_body_now(text, image_variant: image_variant, first_image: first_image,
                             link_section: link_section)
    end

    rendered = false
    key = [ text, image_variant, link_section ]
    html = memoize_entry(:rendered_bodies, key, data.articles, data.assets) do
      rendered = true
      render_body_now(text, image_variant: image_variant, first_image: nil, link_section: link_section)
    end
    # The icons of a body that another page rendered go in the sprite of this page as well.
    record_icons_in(html) unless rendered
    html
  end

  # @see #render_body
  def render_body_now(text, image_variant:, first_image:, link_section: nil)
    srcset = data.srcsets[image_variant]
    render_markup(text) do |doc|
      open_external_links_in_new_tabs(doc)
      track_article_links(doc, link_section) if link_section
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
      restore_list_semantics(doc)
      responsivize_tables(doc)
      scope_table_headers(doc)
      split_table_cell_annotations(doc)
      add_heading_permalinks(doc)
      set_iframe_titles(doc)
      responsivize_iframes(doc)
      lazy_load_iframes(doc)
    end
  end

  # Renders the body of an entry for the Atom feed. It does not do the transforms that a feed
  # reader cannot use.
  #
  # ⚠️ The code keeps the result by text. The main feed renders the 25 newest entries, and the
  # feed of each tag renders the first 25 of that tag. Thus one entry is in many feeds, and
  # without the memo the build renders its body again for each one.
  # @return [String] The HTML after the transforms.
  def render_feed_body(text)
    memoize_entry(:rendered_feed_bodies, text, data.articles, data.assets) { render_feed_body_now(text) }
  end

  # @see #render_feed_body
  def render_feed_body_now(text)
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
  # @return [String] The HTML after the transforms.
  def render_home_body(text)
    render_markup(text, degrees: false) do |doc|
      add_image_data_attributes(doc)
      add_figure_elements_to_images(doc, base_class: "home")
      set_caption_credit(doc)
      # ⚠️ `first_image: :eager` is correct HERE and almost nowhere else. This image is the LCP
      # element of the home page: it is above the fold, and each other candidate is text. Thus
      # the `home` variant has no `auto` in its `sizes`. Refer to data/srcsets.yml.
      responsivize_images(doc, widths: data.srcsets.home.widths, sizes: data.srcsets.home.sizes.join(", "),
                          square: true, first_image: :eager)
      add_image_placeholders(doc)
      set_alt_text(doc)
    end
  end

  # Renders the description of a taxonomy concept: inline treatments only, no images and no
  # tables.
  # @return [String] The HTML after the transforms.
  def render_tag_description(text)
    render_markup(text) do |doc|
      open_external_links_in_new_tabs(doc)
      add_unit_data_attributes(doc)
      mark_affiliate_links(doc)
    end
  end

  # Adds the title of an entry to the start of its body, as a bold run-in.
  # @param html [String] The rendered body HTML.
  # @param hidden_from_at [Boolean] Marks the run-in aria-hidden, for a page where a
  #   visually-hidden <h1> already speaks the title.
  # @return [String] The body, with the run-in at the start.
  def prepend_title(title, html, hidden_from_at: false)
    doc = Nokogiri::HTML::DocumentFragment.parse(html)

    # ⚠️ The title arrives from `smartypants`, thus it holds entities and no escape. Decode them,
    # then escape the text: a `<` or a `"` in a Contentful title must not become markup.
    plain = HTMLEntities.new.decode(title.to_s)
    # The period goes before a closing double quotation mark, as American style needs.
    plain = plain.sub(/(\p{Alnum})(”*)\z/, '\1.\2')
    aria = hidden_from_at ? ' aria-hidden="true"' : ""
    formatted_title = "<b#{aria}>#{CGI.escapeHTML(plain)}</b>"

    first = doc.children.first
    if first.nil?
      # An intro that renders nothing gives an empty fragment. The run-in is then the full body.
      doc = Nokogiri::HTML::DocumentFragment.parse("<p>#{formatted_title}</p>")
    elsif first.name == "p"
      first.inner_html = "#{formatted_title} #{first.inner_html}"
    else
      new_p = Nokogiri::HTML::DocumentFragment.parse("<p>#{formatted_title}</p>").children.first
      first.add_previous_sibling(new_p)
    end

    doc.to_html
  end

  # Changes the `data-imperial` shorthand from Contentful into the attributes of the units
  # Stimulus controller.
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

  # Puts each table in a <wa-scroller>, thus it scrolls horizontally at a small breakpoint.
  def responsivize_tables(html, css_class: "entry__table")
    with_nokogiri_doc(html) do |doc|
      doc.css("table").each { |table| table.wrap("<wa-scroller class=\"#{css_class}\" orientation=\"horizontal\"></wa-scroller>") }
    end
  end

  # Gives each list in the body an explicit list role.
  #
  # ⚠️ This is not a duplicate of the implicit role. Safari removes the list semantics from
  # VoiceOver for a list with `list-style: none`, and base/_extends.scss sets that on each body
  # list. An <ol> also draws its number from a CSS counter, thus a numbered list reads as prose
  # with no order and no count.
  def restore_list_semantics(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("ul, ol").each { |list| list["role"] = "list" }
    end
  end

  # Marks table header cells as column headers.
  def scope_table_headers(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("thead th").each { |th| th["scope"] = "col" }
    end
  end

  # Puts the text after the first <br> of a table cell in an element. Thus the annotation at the
  # end can be less prominent than the measurement that it describes.
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
  def add_heading_permalinks(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("h2, h3").each do |heading|
        heading_id = heading["id"]
        next if heading_id.blank?
        heading_text = heading.text
        # ⚠️ Give the heading a name before you put the permalink in it. Without this name, the
        # name of the heading includes the aria-label of the anchor, and each heading speaks as
        # "Permalink to Foo Foo". The link stays accessible, because nothing hides it.
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

  # Marks each Amazon Associates link as sponsored and opens it in a new tab. It adds to the rel
  # that the author wrote, as open_external_links_in_new_tabs does.
  def mark_affiliate_links(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("a").each do |a|
        next unless amazon_associates_link?(a["href"])

        a["rel"] = (%w[sponsored nofollow noopener] + a["rel"].to_s.split).uniq.join(" ")
        a["target"] = "_blank"
      end
    end
  end

  # Adds target=_blank and rel=noopener to each link to a different site.
  def open_external_links_in_new_tabs(html)
    with_nokogiri_doc(html) do |doc|
      current_host = URI.parse(root_url).host
      doc.css("a").each do |a|
        href = a["href"]
        next unless href&.start_with?("http://", "https://")

        # A link from the author can be incorrect. Ignore such a link and do not stop the build.
        link_host = URI.parse(href).host rescue next
        next if link_host.blank? || link_host == current_host

        # Add to the rel that the author wrote: a `nofollow` or a `ugc` must stay.
        a["rel"] = (a["rel"].to_s.split + [ "noopener" ]).uniq.join(" ")
        a["target"] = "_blank"
      end
    end
  end

  # Adds the Article Click analytics classes to each link to an article on this site.
  def track_article_links(html, section)
    with_nokogiri_doc(html) do |doc|
      current_host = URI.parse(root_url).host
      doc.css("a[href]").each do |a|
        next if a["class"].to_s.include?("plausible-event-name")

        # A link from the author can be incorrect. Ignore such a link and do not stop the build.
        uri = URI.parse(a["href"]) rescue next
        next unless uri.host.nil? || uri.host == current_host
        next unless uri.path&.match?(ARTICLE_PATH_REGEX)

        a["class"] = [ a["class"], article_click_classes(section) ].reject(&:blank?).join(" ")
      end
    end
  end

  # Renders a tag that is connected to the units Stimulus controller.
  # @param attrs [Hash] More attributes for the element, for example a class. A `title` replaces
  #   the default "metric | imperial", for a number whose unit is in another element.
  def units_tag(metric, imperial, tag = :span, **attrs)
    title = attrs.delete(:title) || "#{metric} | #{imperial}"
    content_tag tag.to_sym, 'data-controller': "units", 'data-units-imperial-value': imperial, 'data-units-metric-value': metric, title: title, **attrs do
      metric
    end
  end

  # Makes each link to a feed copy its URL to the clipboard. The link does not navigate.
  def copy_feed_links(html)
    with_nokogiri_doc(html) do |doc|
      doc.css("a").each do |link|
        href = link["href"]
        next unless href&.end_with?("/feed.xml")

        SiteHelpers::FEED_CLIPBOARD_ATTRS.each { |name, value| link[name.to_s] = value }
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

  private

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

  # The intro and the body of an entry, rendered and parsed one time for each entry. The word
  # count, the affiliate scan, and the CSP embed origins each read it, and none of them renders
  # the Markdown again.
  #
  # ⚠️ Read it, and do not change it: the same fragment goes to each reader.
  # @param entry [Object] An article or a page.
  # @return [Nokogiri::HTML::DocumentFragment]
  def entry_fragment(entry)
    id = entry.sys&.id
    return parse_entry_fragment(entry) if id.blank? || !respond_to?(:data)

    memoize_entry(:entry_fragments, id, data.articles, data.pages) { parse_entry_fragment(entry) }
  end

  # @see #entry_fragment
  def parse_entry_fragment(entry)
    text = [ entry.intro, entry.body ].reject(&:blank?).join("\n\n")
    Nokogiri::HTML::DocumentFragment.parse(markdown_to_html(text))
  end

  # The shared shape of the render_*_body pipelines: render the Markdown, parse it one time, give
  # the fragment to the transform steps of the variant, then serialize it.
  # @param degrees [Boolean] True to correct the degree notation first.
  # @yield [Nokogiri::HTML::DocumentFragment] The parsed body, for transforms in place.
  # @return [String] The HTML after the transforms.
  def render_markup(text, degrees: true)
    html = markdown_to_html(degrees ? fix_degrees(text) : text)
    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    yield doc
    strip_scratch_attributes(doc)
    doc.to_html
  end

  # Removes the attributes that add_image_data_attributes writes for the transforms. ⚠️ They must
  # not reach the build: `data-original-url` names the Contentful host, which the image mirror
  # exists to keep off the page and out of the feed.
  # @param doc [Nokogiri::XML::Node] The parsed body.
  def strip_scratch_attributes(doc)
    doc.css("img[data-asset-id], img[data-original-url]").each do |img|
      img.remove_attribute("data-asset-id")
      img.remove_attribute("data-original-url")
    end
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

  # Lets a transform take an HTML string or a parsed node. It gives a document for both, and it
  # changes a node in place.
  # @param html [String, Nokogiri::XML::Node] The HTML to change.
  # @yield [Nokogiri::HTML::DocumentFragment] The document to change.
  # @return [String, Nokogiri::XML::Node, nil] The same type as the input, or nil for a blank
  #   String.
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
