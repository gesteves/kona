require "nokogiri"

# Reads the Open Graph tags of a URL, and its standard.site link tags, for the website card of a
# post.
#
# ⚠️ The card of a social post comes from **the page itself**, and not from Contentful. The URL can be a
# Short, which has no cover image, or a page on another site. Thus the page that the owner links to
# is the only thing that knows its own picture and its own summary.
#
# It never raises: a page with no tags, or a host that is away, gives a card with the URL alone.
# Such a card is not `embeddable?`, and the caller then puts the link in the words of the post.
class OpenGraph < ApplicationService
  # A card that this app read.
  #
  # `document_uri` and `publication_uri` are the `at://` URIs of the standard.site records of the
  # page, from its `<link rel>` tags. They are nil for a page that publishes none, and Bluesky then
  # renders an ordinary link card.
  Card = Data.define(:url, :title, :description, :image_url, :document_uri, :publication_uri) do
    # ⚠️ The two standard.site fields default to nil. Most pages publish neither, thus a caller
    # that makes an ordinary card must not have to name them.
    def initialize(document_uri: nil, publication_uri: nil, **rest)
      super
    end

    # ⚠️ **This is the rule that decides where the link of a post goes.** Bluesky draws a card
    # from the title, the description, and the picture. A page that gives none of the three makes
    # an empty box with a host name in it, thus the caller puts the link in the words instead, as
    # Mastodon does. `Admin::SocialController` and `BlueskyPostJob` both read this.
    # @return [Boolean] True when the page gives enough tags to draw a card.
    def embeddable?
      title.present? || description.present? || image_url.present?
    end
  end

  # ⚠️ A default user agent gets a 403 from many hosts, and the card is then empty with no reason.
  USER_AGENT = "kona/1.0 (+https://github.com/gesteves/kona)".freeze

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # The most bytes of a page that this reads. The tags are in the <head>, thus the read stops at
  # this limit and the rest of the body never arrives.
  MAX_BYTES = 2 * 1024 * 1024

  # The cache is short. The owner can edit a title and share the post again a minute later.
  CACHE_TTL = 15.minutes

  # @param url [String, nil]
  # @return [Boolean] True for an http or https URL.
  def self.http_url?(url)
    uri = URI.parse(url.to_s)
    uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end

  # Reads the card of a URL.
  # @param url [String] An http or https URL.
  # @return [Card] The card. Each field but `url` can be nil.
  def fetch(url)
    return blank_card(url) unless self.class.http_url?(url)

    data = cached_json("open_graph:#{Digest::SHA256.hexdigest(url)}", expires_in: CACHE_TTL) do
      read(url)
    end
    data ||= {}

    Card.new(url: url, title: data[:title], description: data[:description],
             image_url: data[:image_url], document_uri: data[:document_uri],
             publication_uri: data[:publication_uri])
  end

  # @return [Card] A card with the URL and nothing else.
  def blank_card(url)
    Card.new(url: url, title: nil, description: nil, image_url: nil, document_uri: nil,
             publication_uri: nil)
  end

  private

  # Gets the page and reads its tags. It fails soft: the caller then has the URL alone.
  # @return [Hash] { title:, description:, image_url: }
  def read(url)
    page = download(url, max_bytes: MAX_BYTES, keep_head: true,
                         headers: { "User-Agent" => USER_AGENT, "Accept" => "text/html" },
                         open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT,
                         follow_redirects: true, limit: 5)
    return {} if page.nil?

    # ⚠️ A relative og:image resolves against the final URL, after each redirect, and not against
    # the URL that the owner typed.
    parse(page[:body], page[:url])
  rescue StandardError => e
    report_upstream_error(e, context: "Open Graph read", url: url)
    {}
  end

  # @param html [String]
  # @param url [String] The page, to make a relative image URL absolute.
  # @return [Hash]
  def parse(html, url)
    doc = Nokogiri::HTML(html)

    {
      title: meta(doc, "og:title") || doc.at_css("title")&.text&.strip.presence,
      description: meta(doc, "og:description") || meta_name(doc, "description"),
      image_url: absolute(meta(doc, "og:image") || meta_name(doc, "twitter:image"), url),
      document_uri: at_uri(doc, "site.standard.document"),
      publication_uri: at_uri(doc, "site.standard.publication")
    }
  end

  # Reads one standard.site `<link rel>` tag.
  #
  # ⚠️ A crawler of Bluesky runs no JavaScript, thus these tags must come from the server. The build
  # of `web/` writes both of them into the head of each published post
  # (`web/source/partials/_head.html.erb`). A page with no such tag gets an ordinary card.
  # @param rel [String] "site.standard.document" or "site.standard.publication".
  # @return [String, nil] The at:// URI, or nil when the page has no such tag.
  def at_uri(doc, rel)
    value = doc.at_css(%(link[rel="#{rel}"]))&.[]("href")&.strip
    value if value.to_s.start_with?("at://")
  end

  # @return [String, nil] The content of a `property` meta tag.
  def meta(doc, property)
    doc.at_css(%(meta[property="#{property}"]))&.[]("content")&.strip.presence
  end

  # Some pages use `name` and not `property` for the same tag.
  # @return [String, nil] The content of a `name` meta tag.
  def meta_name(doc, name)
    doc.at_css(%(meta[name="#{name}"]))&.[]("content")&.strip.presence
  end

  # @param value [String, nil] An image URL, which can be relative.
  # @param base [String] The page it came from.
  # @return [String, nil] An absolute URL.
  def absolute(value, base)
    return if value.blank?

    URI.join(base, value).to_s
  rescue StandardError
    nil
  end
end
