require "nokogiri"
require "public_suffix"

module AffiliateLinksHelpers
  # Tells if the intro or the body of an entry has an Amazon Associates link. The app keeps the
  # value for each entry, because the render and the parse of the full article are slow and the
  # disclosure partial reads it more than one time on each page.
  #
  # ⚠️ The store is at the module level, by collection, and not an instance variable. Each rendered
  # file has its own template context, and the disclosure partial of each feed reads this for each
  # entry. Thus an instance variable would make the full parse run again in each file.
  # ⚠️ Both collections are in the key, because the about page reads this too. Refer to
  # MemoizationHelpers#memoize_by_collection.
  def has_amazon_associates_links?(content)
    collections = respond_to?(:data) ? [ data.articles, data.pages ] : [ nil ]
    memoize_entry(:amazon_associates_links, content.sys&.id, *collections) do
      scan_for_amazon_associates_links(content)
    end
  end

  # @see #has_amazon_associates_links?
  def scan_for_amazon_associates_links(content)
    entry_fragment(content).css("a").any? { |a| amazon_associates_link?(a["href"]) }
  end

  # True for an amzn.to URL, and for an amazon.com URL with a `tag` parameter.
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
  # @return [String, nil] The disclosure as HTML, or nil when no disclosure applies.
  def affiliate_links_disclosure(entry)
    disclosure = []
    disclosure << "This #{entry_type(entry)&.downcase || 'post'} contains affiliate links, which means I may earn a commission at no additional cost to you if you make a purchase through these links." if show_affiliate_links_disclosure?(entry)
    disclosure << "As an Amazon Associate I earn from qualifying purchases." if has_amazon_associates_links?(entry)
    markdown_to_html(disclosure.join(" "))
  end

  # @return [Boolean] True if the general affiliate disclosure applies.
  def show_affiliate_links_disclosure?(entry)
    entry.show_affiliate_links_disclosure || has_amazon_associates_links?(entry)
  end
end
