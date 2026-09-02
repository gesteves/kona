require "nokogiri"

module MarkupHelper
  # Renders a tag that is connected to the units Stimulus controller. It uses the content_tag form
  # with no block, on purpose: the block form needs an output buffer, and a presenter has none.
  # @param attrs [Hash] More attributes for the element, for example a class. A `title` replaces
  #   the default "metric | imperial", for a number whose unit is in another element.
  def units_tag(metric, imperial, tag = :span, **attrs)
    title = attrs.delete(:title) || "#{metric} | #{imperial}"
    content_tag tag.to_sym, metric, "data-controller": "units", "data-units-imperial-value": imperial, "data-units-metric-value": metric, title: title, **attrs
  end

  # Renders the Markdown body of a card into HTML. This is a small part of the render_body of the
  # static site, on purpose. The body of a card is short text, thus this code does not do the asset,
  # figure, srcset, and blurhash steps, which need the asset index from the build. It does only the
  # two transforms that these bodies need. A Markdown image or table becomes a plain element.
  # @param text [String, nil] The Markdown.
  # @return [String, nil] The HTML, or nil for a blank input.
  def render_summary_body(text)
    html = markdown_to_html(fix_degrees(text))
    return if html.blank?
    doc = Nokogiri::HTML::DocumentFragment.parse(html)
    add_unit_data_attributes(doc)
    open_external_links_in_new_tabs(doc)
    # ⚠️ This must come after open_external_links_in_new_tabs, and never before. Both write `rel`,
    # and the sponsored disclosure must be the value that stays. The render_body of the static site
    # has the same order, for the same reason.
    mark_affiliate_links(doc)
    doc.to_html
  end

  private

  # Marks each Amazon Associates link as sponsored. This is the same as
  # MarkupHelpers#mark_affiliate_links of the static site: an article summary in a widget fragment
  # must have the same disclosure that it has on the page.
  def mark_affiliate_links(doc)
    doc.css("a").each do |a|
      next unless amazon_associates_link?(a["href"])
      a["rel"] = "sponsored nofollow noopener"
      a["target"] = "_blank"
    end
    doc
  end

  # ⚠️ This matches the domain by the end of the host name, and it does not use PublicSuffix. The
  # web app uses PublicSuffix, but this app does not have that dependency. Keep the two the same.
  # @param url [String, nil]
  # @return [Boolean] True if the URL is an Amazon Associates link.
  def amazon_associates_link?(url)
    uri = URI.parse(url.to_s)
    host = uri.host.to_s.downcase
    return true if domain?(host, "amzn.to")
    return false unless domain?(host, "amazon.com")

    URI.decode_www_form(uri.query.to_s).to_h.key?("tag")
  rescue StandardError
    # An href from the author with an incorrect shape is not an affiliate link.
    false
  end

  # @return [Boolean] True if host is `domain`, or a subdomain of it.
  def domain?(host, domain)
    host == domain || host.end_with?(".#{domain}")
  end

  # Changes the `data-imperial` shorthand from Contentful into the attributes of the units
  # controller.
  def add_unit_data_attributes(doc)
    doc.css("[data-imperial]").each do |element|
      replacement = units_tag(element.text, element["data-imperial"], element.name.to_sym)
      element.replace(Nokogiri::HTML::DocumentFragment.parse(replacement))
    end
    doc
  end

  # Opens each absolute link in a new tab. ⚠️ This does not have the same-host exception of the web
  # helper, on purpose, because these bodies link only to external race sites. In each other way it
  # is the same, and this includes the code that ignores an href with an incorrect shape.
  def open_external_links_in_new_tabs(doc)
    doc.css("a").each do |a|
      href = a["href"]
      next unless href&.start_with?("http://", "https://")
      # A link from the author can be incorrect. Ignore such a link and do not change it.
      link_host = URI.parse(href).host rescue next
      next if link_host.blank?

      a["rel"] = "noopener"
      a["target"] = "_blank"
    end
    doc
  end
end
