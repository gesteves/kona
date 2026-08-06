require 'nokogiri'
require 'public_suffix'

module AffiliateLinksHelpers
  # Whether an entry's intro or body contains Amazon Associates links. Memoized per entry,
  # since rendering and parsing the whole article is expensive and the disclosure partial
  # consults it several times per page.
  # @param content [Object] The entry.
  # @return [Boolean]
  def has_amazon_associates_links?(content)
    memoize_by_key(:@has_amazon_associates_links, content.sys&.id) do
      scan_for_amazon_associates_links(content)
    end
  end

  # @see #has_amazon_associates_links?
  def scan_for_amazon_associates_links(content)
    text = [content.intro, content.body].compact.join("\n\n")
    doc = Nokogiri::HTML::DocumentFragment.parse(markdown_to_html(text))
    doc.css('a').each do |a|
      return true if amazon_associates_link?(a['href'])
    end
    false
  end

  # @param url [String] The URL to check.
  # @return [Boolean] Whether the URL is an Amazon Associates link.
  def amazon_associates_link?(url)
    uri = URI.parse(url)
    params = uri.query ? URI.decode_www_form(uri.query).to_h : {}
    domain = PublicSuffix.domain(uri.host)
    domain == 'amzn.to' || (domain == 'amazon.com' && params.key?('tag'))
  rescue StandardError
    # Malformed author-supplied hrefs just aren't affiliate links.
    false
  end

  # Builds the affiliate-link disclosure for an entry.
  # @param entry [Object] The entry.
  # @return [String] The disclosure as HTML, empty when none applies.
  def affiliate_links_disclosure(entry)
    disclosure = []
    disclosure << "This #{entry_type(entry)&.downcase || 'post'} contains affiliate links, which means I may earn a commission at no additional cost to you if you make a purchase through these links." if show_affiliate_links_disclosure?(entry)
    disclosure << "As an Amazon Associate I earn from qualifying purchases." if has_amazon_associates_links?(entry)
    markdown_to_html(disclosure.join(" "))
  end

  # @param entry [Object] The entry.
  # @return [Boolean] Whether the general affiliate disclosure applies.
  def show_affiliate_links_disclosure?(entry)
    entry.show_affiliate_links_disclosure || has_amazon_associates_links?(entry)
  end
end
