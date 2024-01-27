require 'redcarpet'
require 'nokogiri'
require 'active_support/all'
require 'mini_magick'
require 'httparty'
require 'base64'
require 'blurhash'

module CustomHelpers
  include ActiveSupport::NumberHelper

  def full_url(resource, params = {})
    base_url = if ENV['NETLIFY'] && ENV['CONTEXT'] == 'production'
      ENV['URL']
    elsif ENV['NETLIFY'] && ENV['CONTEXT'] != 'production'
      ENV['DEPLOY_URL']
    else
      'http://localhost:4567'
    end
    url = URI.parse(base_url)
    url.path = url_for(resource)
    url.query = URI.encode_www_form(params) if params.present?
    url.to_s
  end

  def atom_tag(url, date = nil)
    tag = url.gsub(/^http(s)?:\/\//, '').gsub('#', '/').split('/')
    tag[0] = "tag:#{tag[0]},#{date.strftime('%Y-%m-%d')}:"
    tag.join('/')
  end

  def page_title(content)
    if content.is_a? Hash
      if content&.current_page.to_i > 1
        [content.title, "Page #{content.current_page}"]
      elsif content.title.present? && content.isHomePage.blank?
        content.title
      end
    elsif content.is_a? String
      content
    else
      data.site.metaTitle
    end
  end

  def title_tag(content, separator: ' · ')
    title = page_title(content)
    strip_tags(smartypants([title, data.site.metaTitle].flatten.reject(&:blank?).uniq.join(separator)))
  end

  def og_title(content, separator: ' · ')
    title = page_title(content)
    strip_tags(smartypants([title].flatten.reject(&:blank?).uniq.join(separator)))
  end

  def content_summary(content)
    if content.summary.present?
      content.summary
    else
      data.site.metaDescription
    end
  end

  def hide_from_search_engines?(content)
    return true if content.draft
    !content.indexInSearchEngines
  end

  def markdown_to_html(text)
    return if text.blank?
    renderer = Redcarpet::Render::HTML.new(with_toc_data: true)
    markdown = Redcarpet::Markdown.new(renderer, fenced_code_blocks: true, disable_indented_code_blocks: true, tables: true, autolink: true, superscript: true)
    Redcarpet::Render::SmartyPants.render(markdown.render(text))
  end

  def markdown_to_text(text)
    strip_tags(markdown_to_html(text))
  end

  def smartypants(text)
    return '' if text.blank?
    Redcarpet::Render::SmartyPants.render(text)
  end

  def remove_widows(text)
    return if text.blank?
    words = text.split(/\s+/)
    return text if words.size == 1
    last_words = words.pop(2).join('&nbsp;')
    words.append(last_words).join(' ')
  end

  def comma_join_with_and(items)
    items.size <= 2 ? items.join(' and ') : [items[0..-2].join(', '), items[-1]].join(' and ')
  end

  def pagination_path(page:)
    if page == 1
      "/blog/index.html"
    else
      "/blog/page/#{page}/index.html"
    end
  end

  def get_asset_id(url)
    url.split('/')[4]
  end

  def get_asset_dimensions(asset_id)
    asset = data.assets.find { |a| a.sys.id == asset_id }
    return asset&.width, asset&.height
  end

  def get_asset_description(asset_id)
    asset = data.assets.find { |a| a.sys.id == asset_id }
    asset&.description&.strip
  end

  def get_asset_content_type(asset_id)
    asset = data.assets.find { |a| a.sys.id == asset_id }
    asset&.contentType
  end

  def get_asset_url(asset_id)
    asset = data.assets.find { |a| a.sys.id == asset_id }
    asset&.url
  end

  def netlify_image_url(original_url, params = {}, config = {})
    base_path = '/.netlify/images'
    netlify_base_url = ENV['CONTEXT'] == 'dev' ? "http://localhost:8888#{base_path}" : base_path
    original_url = "https:#{original_url}" if original_url.start_with?('//')

    query_params = URI.encode_www_form(params)
    url_with_params = "#{netlify_base_url}?url=#{URI.encode_www_form_component(original_url)}"
    url_with_params += "&#{query_params}" unless query_params.empty?

    url_with_params
  end

  def srcset(url:, widths:, square: false, options: {})
    srcset = widths.map do |w|
      query = options.merge({ w: w })
      query.merge!({ h: w }) if square
      netlify_image_url(url, query) + " #{w}w"
    end
    srcset.join(', ')
  end

  def source_tag(url, options = {})
    srcset_opts = { fm: options[:format] }.compact
    options[:srcset] = srcset(url: url, widths: options[:widths], square: options[:square], options: srcset_opts)
    options.delete(:widths)
    options.delete(:format)
    tag :source, options
  end

  def blurhash_svg(asset_id)
    data_uri = blurhash_data_uri(asset_id)
    return if data_uri.blank?

    width, height = get_asset_dimensions(asset_id)

    # Construct the SVG string using Ruby string interpolation
    "<svg xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' viewBox='0 0 #{width} #{height}'>
      <filter id='blur' filterUnits='userSpaceOnUse' color-interpolation-filters='sRGB'>
        <feGaussianBlur stdDeviation='100' edgeMode='duplicate' />
        <feComponentTransfer>
          <feFuncA type='discrete' tableValues='1 1' />
        </feComponentTransfer>
      </filter>
      <image filter='url(#blur)' xlink:href='#{data_uri}' x='0' y='0' height='100%' width='100%'/>
    </svg>"
  end

  def css_placeholder_background(asset_id)
    svg = blurhash_svg(asset_id)
    return if svg.blank?

    "--placeholder:url('data:image/svg+xml;charset=utf-8,#{URI.encode_www_form_component(svg.gsub(/\s+/, ' '))}');"
  end


  def responsivize_images(html, widths: [100, 200, 300], sizes: '100vw', formats: ['avif', 'webp', 'jpg'], lazy: true, square: false)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('img').each do |img|
      asset_id = get_asset_id(img['src'])
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

      img['src'] = netlify_image_url(img['src'])
      img['data-asset-id'] = asset_id

      placeholder_style = css_placeholder_background(asset_id)
      img['style'] = placeholder_style unless placeholder_style.blank?
      img['class'] = [img['class'], 'placeholder'].compact.join(' ')

      # Skip to the next image if it's a gif.
      next if content_type == 'image/gif'

      # Then wrap it in a picture element.
      img.wrap('<picture></picture>')

      # Add a source element for each image format,
      # as a sibling of the img element in the picture tag.
      formats.each do |format|
        img.add_previous_sibling(source_tag(img['src'], sizes: sizes, type: "image/#{format}", format: format, widths: img_widths, square: square))
      end
    end
    doc.to_html
  end

  def resize_images(html, width: 1000)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('img').each do |img|
      asset_id = get_asset_id(img['src'])
      asset_width, _ = get_asset_dimensions(asset_id)
      content_type = get_asset_content_type(asset_id)

      img['src'] = netlify_image_url(img['src'])
      img['data-asset-id'] = asset_id
      next if content_type == 'image/gif'

      resize_width = [width, asset_width].compact.min
      img['src'] = netlify_image_url(img['src'], { w: resize_width })
    end
    doc.to_html
  end


  def set_alt_text(html)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('img').each do |img|
      asset_id = img['data-asset-id'] || get_asset_id(img['src'])
      alt_text = get_asset_description(asset_id)
      img['alt'] = alt_text if alt_text.present?
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

  def responsivize_tables(html)
    return if html.blank?
    doc = Nokogiri::HTML::DocumentFragment.parse(html)
      doc.css('table').each { |table| table.wrap("<div class=\"entry__table\"></div>") }
    doc.to_html
  end

  def render_body(text)
    html = markdown_to_html(text)
    html = add_figure_elements(html, base_class: 'entry')
    html = responsivize_images(html, widths: data.srcsets.entry.widths, sizes: data.srcsets.entry.sizes.join(', '), formats: data.srcsets.entry.formats)
    html = set_alt_text(html)
    html = mark_affiliate_links(html)
    html = responsivize_tables(html)
    html
  end

  def render_feed_body(text)
    html = markdown_to_html(text)
    html = add_figure_elements(html)
    html = resize_images(html, width: data.srcsets.entry.widths.max)
    html = set_alt_text(html)
    html = mark_affiliate_links(html)
    html
  end

  def render_home_body(text)
    html = markdown_to_html(text)
    html = add_figure_elements(html, base_class: 'home')
    html = responsivize_images(html, widths: data.srcsets.home.widths, sizes: data.srcsets.home.sizes.join(', '), formats: data.srcsets.entry.formats, lazy: false, square: true)
    html = set_alt_text(html)
    html
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

  def has_affiliate_links?(content)
    text = [content.intro, content.body].compact.join("/n/n")
    doc = Nokogiri::HTML::DocumentFragment.parse(markdown_to_html(text))
    doc.css('a').each do |a|
      return true if is_affiliate_link?(a['href'])
    end
    false
  end

  def is_affiliate_link?(url)
    begin
      uri = URI.parse(url)
      params = uri.query ? CGI.parse(uri.query) : {}
      domain = PublicSuffix.domain(uri.host)
      domain == 'amzn.to' || domain == 'amazon.com' && params.include?('tag')
    rescue
      false
    end
  end

  def related_articles(article, count: 4)
    tags = article.contentfulMetadata.tags.map(&:id)
    data.articles
      .reject { |a| a.path == article.path } # Reject the article itself
      .reject { |a| a.draft } # Reject drafts
      .reject { |a| a.entry_type == 'Short' } # Reject short posts
      .sort { |a,b| (b.contentfulMetadata.tags.map(&:id) & tags).size <=> (a.contentfulMetadata.tags.map(&:id) & tags).size } # Fake relevancy sorting by sorting by number of common tags
      .slice(0, count) # Slice the specified number of articles
  end

  def random_articles(count: 5)
    data.articles.reject { |a| a.draft || a.entry_type == 'Short' }.shuffle.slice(0, count)
  end

  def recent_articles(count: 5)
    data.articles.reject { |a| a.draft || a.entry_type == 'Short' }.slice(0, count)
  end

  def site_icon(w:)
    original_url = data.site.logo.url
    netlify_image_url(original_url, { w: w })
  rescue
    nil
  end

  def site_updated_at
    [
      data.pages.reject { |p| p.draft || !p.indexInSearchEngines }.map { |p| DateTime.parse(p.sys.publishedAt) },
      data.articles.reject { |a| a.draft || !a.indexInSearchEngines }.map { |a| DateTime.parse(a.sys.publishedAt) },
      DateTime.parse(data.site.sys.publishedAt)
    ].flatten.max
  end

  def open_graph_image_url(original_url)
    params = { w: 1200, h: 630, fit: 'fill' }
    netlify_image_url(original_url, params)
  end

  def blurhash_data_uri(asset_id, width: 32)
    return unless ENV['ENABLE_BLURHASH'].present?

    original_width, original_height = get_asset_dimensions(asset_id)
    return unless original_width && original_height

    height = ((original_height.to_f / original_width.to_f) * width).round
    blurhash = get_blurhash(asset_id, width, height)
    return unless Blurhash.valid_blurhash?(blurhash)

    pixels = Blurhash.decode(width, height, blurhash)
    depth = 8
    dimensions = [width, height]
    map = 'rgba'
    image = MiniMagick::Image.get_image_from_pixels(pixels, dimensions, map, depth, 'jpg')
    "data:image/jpeg;base64,#{Base64.strict_encode64(image.to_blob)}"
  rescue => e
    STDERR.puts "Blurhash data URI generation error: #{e.message}"
    nil
  end

  def get_blurhash(asset_id, width, height)
    url = get_asset_url(asset_id)
    blurhash_url = netlify_image_url(url, { fm: 'blurhash', w: width, h: height })
    response = HTTParty.get(blurhash_url)
    response.ok? ? response.body : nil
  rescue
    nil
  end
end
