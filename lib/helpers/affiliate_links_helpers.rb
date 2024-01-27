require 'nokogiri'

module AffiliateLinksHelpers
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
end
