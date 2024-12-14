require 'nokogiri'

module AffiliateLinksHelpers
  # Checks if the provided content contains any Amazon Associates links.
  # @param content [Object] The content object which may contain affiliate links in its intro or body.
  # @return [Boolean] True if affiliate links are found, otherwise false.
  def has_amazon_associates_links?(content)
    text = [content.intro, content.body].compact.join("/n/n")
    doc = Nokogiri::HTML::DocumentFragment.parse(markdown_to_html(text))
    doc.css('a').each do |a|
      return true if is_amazon_associates_link?(a['href'])
    end
    false
  end

  # Determines if a given URL is an Amazon Associates link.
  # @param url [String] The URL to be checked for being an affiliate link.
  # @return [Boolean] True if the URL is an Amazon Associates link, otherwise false.
  def is_amazon_associates_link?(url)
    begin
      uri = URI.parse(url)
      params = uri.query ? CGI.parse(uri.query) : {}
      domain = PublicSuffix.domain(uri.host)
      domain == 'amzn.to' || domain == 'amazon.com' && params.include?('tag')
    rescue
      false
    end
  end

  # Returns an appropriate disclosure for entries containing affliate links.
  # @param entry [Object] The entry.
  # @return [String] A disclosure message for the entry.
  def affiliate_links_disclosure(entry)
    disclosure = []
    disclosure << "This #{entry_type(entry).downcase} contains affiliate links, which means I may earn a commission at no additional cost to you if you make a purchase through these links." if show_affiliate_links_disclosure?(entry)
    disclosure << "As an Amazon Associate I earn from qualifying purchases." if has_amazon_associates_links?(entry)
    markdown_to_html(remove_widows(disclosure.join(" ")))
  end

  # Determines if the affiliate links disclosure should be shown for the provided entry.
  # @param entry [Object] The entry.
  # @return [Boolean] True if the disclosure should be shown, otherwise false.
  def show_affiliate_links_disclosure?(entry)
    entry.show_affiliate_links_disclosure || has_amazon_associates_links?(entry)
  end
end
