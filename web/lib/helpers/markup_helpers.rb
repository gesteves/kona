require "cgi"
require "erb"
require "htmlentities"
require "nokogiri"

# Renders a Markdown body and does the HTML transformations that the Contentful editor cannot do.
# This module holds each pipeline and the transforms of the text: units, links, tables, and
# heading permalinks. MarkupImageHelpers holds the transforms of the images, and
# MarkupEmbedHelpers those of the iframes.
#
# Each transform takes `html` as a String or as a parsed Nokogiri node, and it returns the same
# type. Refer to #with_nokogiri_doc.
module MarkupHelpers
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
  # @param first_image [Symbol, nil] Refer to MarkupImageHelpers#responsivize_images.
  # @param tracking_section [String, nil] The analytics section of each link to an article. With nil,
  #   the links get no analytics classes.
  # @return [String] The HTML after the transforms.
  def render_body(text, image_variant: :entry, first_image: nil, tracking_section: nil)
    if first_image
      return compute_render_body(text, image_variant: image_variant, first_image: first_image,
                             tracking_section: tracking_section)
    end

    rendered = false
    key = [ text, image_variant, tracking_section ]
    html = memoize_entry(:rendered_bodies, key, data.articles, data.assets) do
      rendered = true
      compute_render_body(text, image_variant: image_variant, first_image: nil, tracking_section: tracking_section)
    end
    # The icons of a body that another page rendered go in the sprite of this page as well.
    record_icons_in(html) unless rendered
    html
  end

  # @see #render_body
  def compute_render_body(text, image_variant:, first_image:, tracking_section: nil)
    srcset = data.srcsets[image_variant]
    render_markup(text) do |doc|
      open_external_links_in_new_tabs(doc)
      track_article_links(doc, tracking_section) if tracking_section
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
    memoize_entry(:rendered_feed_bodies, text, data.articles, data.assets) { compute_render_feed_body(text) }
  end

  # @see #render_feed_body
  def compute_render_feed_body(text)
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
  #
  # ⚠️ The code escapes the text, because the content_tag of Middleman does not escape a block. The
  # api copy escapes it through Rails, and both copies go on the same page.
  def units_tag(metric, imperial, tag = :span, **attrs)
    title = attrs.delete(:title) || "#{metric} | #{imperial}"
    content_tag tag.to_sym, 'data-controller': "units", 'data-units-imperial-value': imperial, 'data-units-metric-value': metric, title: title, **attrs do
      ERB::Util.html_escape(metric)
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

  # The intro and the body of an entry, rendered and parsed one time for each entry. The word
  # count, the affiliate scan, and the CSP embed origins each read it, and none of them renders
  # the Markdown again.
  #
  # ⚠️ Read it, and do not change it: the same fragment goes to each reader.
  # @param entry [Object] An article or a page.
  # @return [Nokogiri::HTML::DocumentFragment]
  def entry_fragment(entry)
    id = entry.sys&.id
    return compute_entry_fragment(entry) if id.blank? || !respond_to?(:data)

    memoize_entry(:entry_fragments, id, data.articles, data.pages) { compute_entry_fragment(entry) }
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

  private

  # @see #entry_fragment
  def compute_entry_fragment(entry)
    text = [ entry.intro, entry.body ].reject(&:blank?).join("\n\n")
    Nokogiri::HTML::DocumentFragment.parse(markdown_to_html(text))
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
end
