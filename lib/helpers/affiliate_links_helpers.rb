require 'nokogiri'

module AffiliateLinksHelpers
  # Checks if the provided content contains any affiliate links.
  # @param content [Object] The content object which may contain affiliate links in its intro or body.
  # @return [Boolean] True if affiliate links are found, otherwise false.
  def has_affiliate_links?(content)
    text = [content.intro, content.body].compact.join("/n/n")
    doc = Nokogiri::HTML::DocumentFragment.parse(markdown_to_html(text))
    doc.css('a').each do |a|
      return true if is_affiliate_link?(a['href'])
    end
    false
  end

  # Determines if a given URL is an Amazon affiliate link.
  # @param url [String] The URL to be checked for being an affiliate link.
  # @return [Boolean] True if the URL is an Amazon affiliate link, otherwise false.
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
end
