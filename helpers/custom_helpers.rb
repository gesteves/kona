require 'redcarpet'
require 'nokogiri'

module CustomHelpers
  def full_url(resource)
    domain = if config[:netlify] && config[:context] == 'production'
      config[:url]
    elsif config[:netlify] && config[:context] != 'production'
      config[:deploy_url]
    else
      'http://localhost:4567'
    end
    "#{domain}#{url_for(resource)}"
  end

  def atom_tag(url, date = nil)
    tag = url.gsub(/^http(s)?:\/\//, '').gsub('#', '/').split('/')
    tag[0] = "tag:#{tag[0]},#{date.strftime('%Y-%m-%d')}:"
    tag.join('/')
  end

  def page_title(title: nil, content: nil, separator: ' · ')
    if content.present?
      title = if content.current_page.present? && content.current_page > 1
        [content.title, "Page #{content.current_page}"]
      else
        content.title
      end
    end
    smartypants([title, data.site.metaTitle].flatten.reject(&:blank?).uniq.join(separator))
  end

  def og_title(title: nil, content: nil, separator: ' · ')
    if content.present?
      title = if content.current_page.present? && content.current_page > 1
        [content.title, "Page #{content.current_page}"]
      else
        content.title
      end
    end
    title = data.site.metaTitle if title.blank?
    smartypants([title].flatten.reject(&:blank?).uniq.join(separator))
  end

  def content_summary(content)
    if content.summary.present?
      content.summary
    elsif content.intro.present?
      truncate(markdown_to_text(content.intro), length: 280)
    elsif content.body.present?
      truncate(markdown_to_text(content.body), length: 280)
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
    markdown = Redcarpet::Markdown.new(renderer, fenced_code_blocks: true, disable_indented_code_blocks: true, tables: true)
    Redcarpet::Render::SmartyPants.render(markdown.render(text))
  end

  def markdown_to_text(text)
    strip_tags(markdown_to_html(text))
  end

  def smartypants(text)
    return '' if text.blank?
    Redcarpet::Render::SmartyPants.render(text)
  end

  def source_tag(url, options = {})
    srcset_opts = { fm: options[:format] }.compact
    options[:srcset] = srcset(url: url, widths: options[:widths], options: srcset_opts)
    options.delete(:widths)
    options.delete(:format)
    tag :source, options
  end

  def srcset(url:, widths:, options: {})
    url = URI.parse(url)
    srcset = widths.map do |w|
      query = options.merge!({ w: w })
      url.query = URI.encode_www_form(query)
      "#{url.to_s} #{w}w"
    end
    srcset.join(', ')
  end

  def pagination_path(entry_type:, page:)
    if page == 1
      "/index.html"
    else
      "/page/#{page}/index.html"
    end
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

  def get_asset_id(url)
    url.split('/')[4]
  end

  def responsivize_images(html, widths: [100, 200, 300], sizes: '100vw', formats: ['avif', 'webp', 'jpg'])
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('img').each do |img|
      # Set the width & height of the image,
      # and make it lazy-load.
      asset_id = get_asset_id(img['src'])
      width, height = get_asset_dimensions(asset_id)
      content_type = get_asset_content_type(asset_id)

      img['loading'] = 'lazy'
      if width.present? && height.present?
        img['width'] = width
        img['height'] = height
      end

      # Skip to the next image if it's a gif.
      next if content_type == 'image/gif'

      # Then wrap it in a picture element.
      img.wrap('<picture></picture>')

      # Add a source element for each image format,
      # as a sibling of the img element in the picture tag.
      formats.each do |format|
        img.add_previous_sibling(source_tag(img['src'], sizes: sizes, type: "image/#{format}", format: format, widths: widths))
      end
    end
    doc.to_html
  end

  def set_alt_text(html)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('img').each do |img|
      asset_id = get_asset_id(img['src'])
      alt_text = get_asset_description(asset_id)
      img['alt'] = alt_text if alt_text.present?
    end
    doc.to_html
  end

  def add_figure_elements(html)
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
      # Wrap the whole thing in a figure element,
      # with the caption in a figcaption, if present,
      # then replace the original paragraph with it.
      img.wrap('<figure></figure>')
      img.add_next_sibling("<figcaption>#{caption}</figcaption>") if caption.present?
      parent.replace(img.parent)
    end
    doc.to_html
  end

  def set_caption_credit(html)
    parts = html.split(' | ')
    return html if parts.size == 1
    "#{parts.first} <cite>#{parts.last}</cite>"
  end

  def set_code_language(html)
    return if html.blank?

    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    doc.css('code').each do |code|
      code['class'] = "language-#{code['class']}" if code['class'].present?
    end
    doc.to_html
  end

  def render_body(text)
    mark_affiliate_links(set_code_language(set_alt_text(responsivize_images(add_figure_elements(markdown_to_html(text)), widths: data.srcsets.entry.widths.sort, sizes: data.srcsets.entry.sizes.join(', '), formats: data.srcsets.entry.formats))))
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
    return true if is_affiliate_link?(content.linkUrl)
    doc = Nokogiri::HTML::DocumentFragment.parse(markdown_to_html(content.body))
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

  def related_articles(article, count: 5)
    tags = article.contentfulMetadata.tags.map(&:id)
    data.articles
      .reject { |a| a.path == article.path } # Reject the article itself
      .reject { |a| a.draft } # Reject drafts
      .select { |a| (a.contentfulMetadata.tags.map(&:id) & tags).present? } # Select the articles with common tags
      .sort { |a,b| (b.contentfulMetadata.tags.map(&:id) & tags).size <=> (a.contentfulMetadata.tags.map(&:id) & tags).size } # Fake relevancy sorting by sorting by number of common tags
      .slice(0, count) # Slice the specified number of articles
      .sort { |a,b| DateTime.parse(b.published_at) <=> DateTime.parse(a.published_at) } # Sort them again in reverse chron
  end

  def site_icon(w:)
    url = URI.parse(data.site.logo.url)
    url.query = URI.encode_www_form(w: w)
    url.to_s
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
end
