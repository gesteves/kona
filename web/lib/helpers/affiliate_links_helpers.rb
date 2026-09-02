require "nokogiri"
require "public_suffix"

module AffiliateLinksHelpers
  # Tells if the intro or the body of an entry has an Amazon Associates link. The app keeps the
  # value for each entry, because the render and the parse of the full article are slow and the
  # disclosure partial reads it more than one time on each page.
  # @param content [Object] The entry.
  # @return [Boolean]
  #
  # ⚠️ The store is at the module level, by collection, and not an instance variable. Each rendered
  # file has its own template context, and the disclosure partial of a feed reads this for each
  # entry of each of the ~40 feeds: an instance variable made the full parse run again in each.
  def has_amazon_associates_links?(content)
    id = content.sys&.id
    return scan_for_amazon_associates_links(content) if id.blank?

    store = memoize_by_collection(:amazon_associates_links, (data.articles if respond_to?(:data))) { {} }
    return store[id] if store.key?(id)

    store[id] = scan_for_amazon_associates_links(content)
  end

  # @see #has_amazon_associates_links?
  def scan_for_amazon_associates_links(content)
    text = [ content.intro, content.body ].compact.join("\n\n")
    doc = Nokogiri::HTML::DocumentFragment.parse(markdown_to_html(text))
    doc.css("a").each do |a|
      return true if amazon_associates_link?(a["href"])
    end
    false
  end

  # @param url [String] The URL to check.
  # @return [Boolean] True if the URL is an Amazon Associates link.
  def amazon_associates_link?(url)
    uri = URI.parse(url)
    params = uri.query ? URI.decode_www_form(uri.query).to_h : {}
    domain = PublicSuffix.domain(uri.host)
    domain == "amzn.to" || (domain == "amazon.com" && params.key?("tag"))
  rescue StandardError
    # An href from the author with an incorrect shape is not an affiliate link.
    false
  end

  # Makes the affiliate-link disclosure of an entry.
  # @param entry [Object] The entry.
  # @return [String] The disclosure as HTML. It is empty when no disclosure applies.
  def affiliate_links_disclosure(entry)
    disclosure = []
    disclosure << "This #{entry_type(entry)&.downcase || 'post'} contains affiliate links, which means I may earn a commission at no additional cost to you if you make a purchase through these links." if show_affiliate_links_disclosure?(entry)
    disclosure << "As an Amazon Associate I earn from qualifying purchases." if has_amazon_associates_links?(entry)
    markdown_to_html(disclosure.join(" "))
  end

  # @param entry [Object] The entry.
  # @return [Boolean] True if the general affiliate disclosure applies.
  def show_affiliate_links_disclosure?(entry)
    entry.show_affiliate_links_disclosure || has_amazon_associates_links?(entry)
  end
end
