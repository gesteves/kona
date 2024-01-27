require 'nokogiri'

module MarkupHelpers
  def render_body(text)
    html = markdown_to_html(text)
    html = add_image_data_attributes(html)
    html = add_figure_elements(html, base_class: 'entry')
    html = responsivize_images(html, widths: data.srcsets.entry.widths, sizes: data.srcsets.entry.sizes.join(', '), formats: data.srcsets.entry.formats)
    html = add_image_placeholders(html)
    html = set_alt_text(html)
    html = mark_affiliate_links(html)
    html = responsivize_tables(html)
    html
  end

  def render_feed_body(text)
    html = markdown_to_html(text)
    html = add_image_data_attributes(html)
    html = add_figure_elements(html)
    html = resize_images(html, width: data.srcsets.entry.widths.max)
    html = set_alt_text(html)
    html = mark_affiliate_links(html)
    html
  end

  def render_home_body(text)
    html = markdown_to_html(text)
    html = add_image_data_attributes(html)
    html = add_figure_elements(html, base_class: 'home')
    html = responsivize_images(html, widths: data.srcsets.home.widths, sizes: data.srcsets.home.sizes.join(', '), formats: data.srcsets.entry.formats, lazy: false, square: true)
    html = add_image_placeholders(html)
    html = set_alt_text(html)
    html
  end

  def source_tag(url, options = {})
    srcset_opts = { fm: options[:format] }.compact
    options[:srcset] = srcset(url: url, widths: options[:widths], square: options[:square], options: srcset_opts)
    options.delete(:widths)
    options.delete(:format)
    tag :source, options
  end

  def css_placeholder_background(asset_id)
    svg = blurhash_svg(asset_id)
    return if svg.blank?

    encoded_svg = ERB::Util.url_encode(svg.gsub(/\s+/, ' '))
    "--placeholder:url('data:image/svg+xml;charset=utf-8,#{encoded_svg}');"
  end

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

  def add_figure_elements(html, base_class: nil)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('img').each do |img|
      # Get the parent of the image
      parent = img.parent
      # Remove the image
      img = img.remove
      # The caption is whatever is left in the parent, so store it...
      caption = set_caption_credit(parent.inner_html)
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

  def set_caption_credit(html)
    return if html.blank?
    parts = html.split(' | ')
    return html if parts.size == 1
    "#{parts.first} <cite>#{parts.last}</cite>"
  end

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

  def add_image_placeholders(html)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('img').each do |img|
      asset_id = img['data-asset-id']

      next if asset_id.blank?

      placeholder_style = css_placeholder_background(asset_id)
      img['style'] = placeholder_style unless placeholder_style.blank?
      img['class'] = [img['class'], 'placeholder'].compact.join(' ')
    end
    doc.to_html
  end

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

  def responsivize_tables(html)
    return if html.blank?
    doc = Nokogiri::HTML::DocumentFragment.parse(html)
      doc.css('table').each { |table| table.wrap("<div class=\"entry__table\"></div>") }
    doc.to_html
  end

  def mark_affiliate_links(html)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('a').each do |a|
      if is_affiliate_link?(a['href'])
        a['rel'] = "sponsored nofollow"
      end
    end
    doc.to_html
  end
end
