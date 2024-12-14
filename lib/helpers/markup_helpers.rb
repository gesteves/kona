require 'nokogiri'

# This module manipulates Markdown content in various ways that are
# hard or impossible to do in the story editor in Contentful,
# e.g. making images and tables responsive, etc.
module MarkupHelpers
  # Renders the body text for an entry with various transformations of the HTML output.
  # @param text [String] The Markdown text to render.
  # @param image_variant [Symbol] The responsive images config to use.
  # @return [String] The rendered HTML with added attributes and transformations.
  def render_body(text, image_variant: :entry)
    srcset = data.srcsets[image_variant]
    html = markdown_to_html(text)
    html = open_external_links_in_new_tabs(html)
    html = add_unit_data_attributes(html)
    html = add_image_data_attributes(html)
    html = add_figure_elements_to_images(html, base_class: 'entry')
    html = add_figure_elements_to_iframes(html, base_class: 'entry')
    html = add_figure_elements_to_embeds(html, base_class: 'entry')
    html = set_caption_credit(html)
    html = responsivize_images(html, widths: srcset.widths, sizes: srcset.sizes.join(', '), formats: srcset.formats)
    html = resize_images(html, width: srcset.widths.max)
    html = add_image_placeholders(html)
    html = set_alt_text(html)
    html = mark_affiliate_links(html)
    html = responsivize_tables(html)
    html = add_heading_permalinks(html)
    html
  end

  # Renders the body text for the Atom feed with various transformations of the HTML output.
  # @param text [String] The Markdown text to render.
  # @return [String] The rendered HTML with added attributes and transformations.
  def render_feed_body(text)
    html = markdown_to_html(text)
    html = add_image_data_attributes(html)
    html = add_figure_elements_to_images(html)
    html = add_figure_elements_to_iframes(html)
    html = add_figure_elements_to_embeds(html)
    html = set_caption_credit(html)
    html = resize_images(html, width: data.srcsets.entry.widths.max)
    html = set_alt_text(html)
    html = mark_affiliate_links(html)
    html
  end

  # Renders the body text for the home page with various transformations of the HTML output.
  # @param text [String] The Markdown text to render.
  # @return [String] The rendered HTML with added attributes and transformations.
  def render_home_body(text)
    html = markdown_to_html(text)
    html = add_image_data_attributes(html)
    html = add_figure_elements_to_images(html, base_class: 'home')
    html = set_caption_credit(html)
    html = responsivize_images(html, widths: data.srcsets.home.widths, sizes: data.srcsets.home.sizes.join(', '), formats: data.srcsets.entry.formats, lazy: false, square: true)
    html = resize_images(html)
    html = add_image_placeholders(html)
    html = set_alt_text(html)
    html
  end

  # Prepends the title of the entry to the body.
  # @param title [String] The title of the entry.
  # @param html [String] The rendered HTML of the body of the entry.
  # @return [String] The body of the entry with the entry at the beginning.
  def prepend_title(title, html)
    doc = Nokogiri::HTML::DocumentFragment.parse(html)

    if title.match?(/(\.$|\.\"$|\.”$)/)
      formatted_title = "<b>#{title}</b>"
    else
      formatted_title = "<b>#{title}.</b>"
    end

    if doc.children.first.name == 'p'
      first_p = doc.children.first
      first_p.inner_html = "#{formatted_title} #{first_p.inner_html}"
    else
      new_p = Nokogiri::HTML::DocumentFragment.parse("<p>#{formatted_title}</p>").children.first
      doc.children.first.add_previous_sibling(new_p)
    end

    doc.to_html
  end

  # Adds data attributes for the units-controller.js Stimulus controller,
  # to simplify entering unit conversion data in Contentful.
  # @param html [String] A string containing the HTML to be processed.
  # @return [String] The modified HTML with updated data attributes.
  # @example
  #   original_html = '<span data-imperial="6.21 mi">10 km</span>'
  #   modified_html = add_unit_data_attributes(original_html)
  #   # => '<span data-units-imperial-value="6.21 mi" data-units-metric-value="10 km" data-controller="units">10 km</span>'
  def add_unit_data_attributes(html)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('[data-imperial]').each do |element|
      imperial_value = element['data-imperial']
      metric_value = element.text
      new_element = units_tag(metric_value, imperial_value, element.name.to_sym)
      element.replace(Nokogiri::HTML::DocumentFragment.parse(new_element))
    end
    doc.to_html
  end

  # Adds data attributes to image elements in HTML to store asset information for later use.
  # @param html [String] The HTML content with image elements.
  # @return [String] The HTML content with added data attributes.
  def add_image_data_attributes(html)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('img').each do |img|
      original_url = img['src']
      asset_id = get_asset_id(original_url)
      img['data-asset-id'] = asset_id
      img['data-original-url'] = original_url
    end
    doc.to_html
  end

  # Adds figure elements around image elements in HTML with an optional CSS class.
  # @param html [String] The HTML content with image elements.
  # @param base_class [String] (Optional) The base class to add to the figure element.
  # @return [String] The HTML content with added figure elements.
  def add_figure_elements_to_images(html, base_class: nil)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('img').each do |img|
      # Get the parent of the image
      parent = img.parent
      # Remove the image
      img = img.remove
      # The caption is whatever is left in the parent, so store it...
      caption = parent.inner_html
      # ...then put the image back
      parent.prepend_child(img)

      # Get the corresponding image asset
      asset_id = get_asset_id(img['src'])
      content_type = get_asset_content_type(asset_id)

      # Wrap the whole thing in a figure element,
      # with the caption in a figcaption, if present,
      # then replace the original paragraph with it.
      figure = if base_class.present?
        figure_class = "#{base_class}__figure #{base_class}__figure--#{content_type.split('/').last}"
        "<figure class=\"#{figure_class}\"></figure>"
      else
        "<figure></figure>"
      end
      img.wrap(figure)
      img.add_next_sibling("<figcaption>#{caption}</figcaption>") if caption.present?
      parent.replace(img.parent)
    end
    doc.to_html
  end

  # Adds figure elements around iframes in HTML with an optional CSS class.
  # @param html [String] The HTML content with iframes.
  # @param base_class [String] (Optional) The base class to add to the figure element.
  # @return [String] The HTML content with added figure elements.
  def add_figure_elements_to_iframes(html, base_class: nil)
    # Parse the HTML with Nokogiri
    doc = Nokogiri::HTML.fragment(html)

    # Loop over every iframe element
    doc.css('iframe').each do |iframe|
      parent = iframe.parent

      # If the iframe's immediate parent is not a figure tag
      if parent.name != 'figure'
        # Create a new figure element and wrap the iframe
        figure = Nokogiri::XML::Node.new('figure', doc)
        iframe.replace(figure)
        figure.add_child(iframe)
        # Update the parent to reference the newly created figure
        parent = figure
      end

      parent['class'] = "#{base_class}__figure #{base_class}__figure--iframe" if base_class.present?
    end

    doc.to_html
  end

  # Adds figure elements around social media embeds in HTML with an optional CSS class.
  # @param html [String] The HTML content with social media embeds.
  # @param base_class [String] (Optional) The base class to add to the figure element.
  # @return [String] The HTML content with added figure elements.
  def add_figure_elements_to_embeds(html, base_class: nil)
    # Parse the HTML with Nokogiri
    doc = Nokogiri::HTML.fragment(html)

    # Loop over every blockquote element immediately followed by a script tag
    # (Bluesky, Instagram, and Threads embeds are blockquotes followed by scripts.)
    doc.css('blockquote + script').each do |script|
      blockquote = script.previous_element

      # Ensure the previous element is actually a blockquote
      next unless blockquote.name == 'blockquote'

      parent = blockquote.parent

      # If the blockquote's immediate parent is not a figure tag
      if parent.name != 'figure'
        # Create a new figure element and wrap the blockquote and script
        figure = Nokogiri::XML::Node.new('figure', doc)
        blockquote.replace(figure)
        figure.add_child(blockquote)
        figure.add_child(script)

        # Update the parent to reference the newly created figure
        parent = figure
      end

      # Set classes if base_class is provided
      parent['class'] = "#{base_class}__figure #{base_class}__figure--embed" if base_class.present?
    end

    doc.to_html
  end


  # Formats the figcaption of figure elements, wrapping the credit in a <cite> element
  # @param html [String] The HTML content with figcaptions.
  # @return [String, nil] The HTML content with caption and credit formatted with <cite>.
  def set_caption_credit(html)
    # Parse the HTML with Nokogiri
    doc = Nokogiri::HTML.fragment(html)

    # Loop over every figcaption element
    doc.css('figcaption').each do |figcaption|
      # Split the text content by ' | '
      parts = figcaption.inner_html.split(' | ')

      # If there are two parts, format with <cite>
      if parts.size > 1
        figcaption.inner_html = "#{parts.first} <cite>#{parts.last}</cite>"
      end
    end

    doc.to_html
  end

  # Makes images responsive within HTML by wrapping image elements in a picture element
  # using source elements with srcsets/sizes in various formats.
  # @param html [String] The HTML content with image elements.
  # @param widths [Array<Integer>] The widths for which to generate responsive images.
  # @param sizes [String] The sizes attribute value for the image element.
  # @param formats [Array<String>] The image formats to include (e.g., 'avif', 'webp', 'jpg').
  # @param lazy [Boolean] Whether to enable lazy loading for images.
  # @param square [Boolean] Whether to crop images square.
  # @return [String] The HTML content with responsive picture elements.
  def responsivize_images(html, widths: [100, 200, 300], sizes: '100vw', formats: ['avif', 'webp', 'jpg'], lazy: true, square: false)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('img').each do |img|
      original_url = img['data-original-url']
      asset_id = img['data-asset-id']

      next if asset_id.blank? || original_url.blank?

      width, height = get_asset_dimensions(asset_id)
      content_type = get_asset_content_type(asset_id)

      img_widths = widths.dup
      if width.present?
        img_widths << width if width < img_widths.max
        img_widths = img_widths.reject { |w| w > width }
      end
      img_widths = img_widths.uniq.sort

      # Set the width & height of the image,
      # and make it lazy-load.
      img['loading'] = 'lazy' if lazy
      if width.present? && height.present?
        img['width'] = width
        img['height'] = square ? width : height
      end

      img['src'] = cdn_image_url(original_url)

      # Skip to the next image if it's a gif.
      next if content_type == 'image/gif'

      # Then wrap it in a picture element.
      img.wrap('<picture></picture>')

      # Add a source element for each image format,
      # as a sibling of the img element in the picture tag.
      formats.each do |format|
        img.add_previous_sibling(source_tag(original_url, sizes: sizes, type: "image/#{format}", format: format, widths: img_widths, square: square))
      end
    end
    doc.to_html
  end

  # Generates a <source> HTML tag with a srcset.
  # @param url [String] The URL of the image.
  # @param options [Hash] (Optional) Additional options for the <source> tag.
  # @return [String] The HTML <source> tag.
  def source_tag(url, options = {})
    srcset_opts = { fm: options[:format] }.compact
    options[:srcset] = srcset(url: url, widths: options[:widths], square: options[:square], options: srcset_opts)
    options.delete(:widths)
    options.delete(:format)
    tag :source, options
  end

  # Resizes images within HTML to a specified width.
  # @param html [String] The HTML content with image elements.
  # @param width [Integer] The maximum width for resized images.
  # @return [String] The HTML content with images resized to the specified width.
  def resize_images(html, width: 1000)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('img').each do |img|
      original_url = img['data-original-url']
      asset_id = img['data-asset-id']

      next if asset_id.blank? || original_url.blank?

      asset_width, _ = get_asset_dimensions(asset_id)
      content_type = get_asset_content_type(asset_id)

      img['src'] = cdn_image_url(img['src'])
      img['data-asset-id'] = asset_id
      next if content_type == 'image/gif'

      resize_width = [width, asset_width].compact.min
      img['src'] = cdn_image_url(original_url, { w: resize_width })
    end
    doc.to_html
  end

  # Adds image placeholders to images in HTML content.
  # @param html [String] The HTML content with image elements.
  # @return [String] The HTML content with image placeholders added as CSS background.
  def add_image_placeholders(html)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('img').each do |img|
      asset_id = img['data-asset-id']

      next if asset_id.blank?

      blurhash_svg_data_uri = blurhash_svg_data_uri(asset_id)
      img['style'] = "--placeholder:url('#{blurhash_svg_data_uri}');" unless blurhash_svg_data_uri.blank?
      img['class'] = [img['class'], 'placeholder'].compact.join(' ')
    end
    doc.to_html
  end

  # Sets alt text for images in HTML content to the assets' descriptions.
  # @param html [String] The HTML content with image elements.
  # @return [String] The HTML content with alt text set for images.
  def set_alt_text(html)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('img').each do |img|
      asset_id = img['data-asset-id']

      next if asset_id.blank?

      alt_text = get_asset_description(asset_id)
      img['alt'] = alt_text if alt_text.present?
    end
    doc.to_html
  end

  # Wraps HTML tables in responsive div containers.
  # @param html [String] The HTML content with table elements.
  # @return [String] The HTML content with tables wrapped in responsive div containers.
  def responsivize_tables(html, css_class: "entry__table")
    return if html.blank?
    doc = Nokogiri::HTML::DocumentFragment.parse(html)
      doc.css('table').each { |table| table.wrap("<div class=\"#{css_class}\"></div>") }
    doc.to_html
  end

  def add_heading_permalinks(html)
    return if html.blank?
    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('h3').each do |heading|
      heading_id = heading['id']
      next if heading_id.blank?
      permalink = <<~HTML
        <a href="##{heading_id}" class="entry__heading-permalink" aria-label="Permalink to “#{heading.text}”" title="Permalink to “#{heading.text}”" data-controller="clipboard" data-clipboard-hidden-class="entry__heading-permalink-icon--hidden" data-clipboard-success-message-value="A link to this section has been copied to your clipboard." data-action="click->clipboard#preventDefault">
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
    doc.to_html
  end

  # Marks affiliate links in HTML content as sponsored, and makes them open in a new tab.
  # @param html [String] The HTML content containing hyperlinks.
  # @return [String] The HTML content with affiliate links marked as sponsored.
  def mark_affiliate_links(html)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('a').each do |a|
      if is_amazon_associates_link?(a['href'])
        a['rel'] = "sponsored nofollow noopener"
        a['target'] = '_blank'
      end
    end
    doc.to_html
  end

  # Opens external links in new tabs.
  # @param html [String] The HTML string to be processed.
  # @return [String] The modified HTML with updated link attributes.
  def open_external_links_in_new_tabs(html)
    return html if html.blank?

    current_host = URI.parse(root_url).host
    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('a').each do |a|
      href = a['href']
      next unless href&.start_with?('http://', 'https://')

      link_host = URI.parse(href).host
      next if link_host.blank? || link_host == current_host

      a['rel'] = 'noopener'
      a['target'] = '_blank'
    end
    doc.to_html
  end

  # Renders a tag with the data-* attributes to attach the unit conversion Stimulus controller.
  # @param metric [String] The text with metric units.
  # @param imperial [String] The text with imperial units.
  # @param tag [Symbol] The HTML to use. Optional, defaults to a <span>.
  # @return [String] An HTML tag.
  def units_tag(metric, imperial, tag = :span)
    content_tag tag.to_sym, 'data-controller': 'units', 'data-units-imperial-value': imperial, 'data-units-metric-value': metric, title: "#{metric} | #{imperial}" do
      metric
    end
  end
end
