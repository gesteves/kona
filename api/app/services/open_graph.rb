require "nokogiri"

# Reads the Open Graph tags of a URL, for the website card of a post.
#
# ⚠️ The card of a share comes from **the page itself**, and not from Contentful. The URL can be a
# Short, which has no cover image, or a page on another site. Thus the page that the owner links to
# is the only thing that knows its own picture and its own summary.
#
# It never raises: a page with no tags, or a host that is away, gives a card with the URL alone, and
# Bluesky renders that.
class OpenGraph < ApplicationService
  # A card that this app read.
  Card = Data.define(:url, :title, :description, :image_url)

  # ⚠️ A default user agent gets a 403 from many hosts, and the card is then empty with no reason.
  USER_AGENT = "kona/1.0 (+https://github.com/gesteves/kona)".freeze

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # The largest page that this reads. The tags are in the <head>, thus a body that goes on for a
  # long time is only a cost.
  MAX_BYTES = 2 * 1024 * 1024

  # The cache is short. The owner can edit a title and share the post again a minute later.
  CACHE_TTL = 15.minutes

  # Reads the card of a URL.
  # @param url [String] An http or https URL.
  # @return [Card] The card. Each field but `url` can be nil.
  def fetch(url)
    return Card.new(url: url, title: nil, description: nil, image_url: nil) unless http_url?(url)

    data = cached_json("open_graph:#{Digest::SHA256.hexdigest(url)}", expires_in: CACHE_TTL) do
      read(url)
    end
    data ||= {}

    Card.new(url: url, title: data[:title], description: data[:description],
             image_url: data[:image_url])
  end

  # @param url [String, nil]
  # @return [Boolean] True for an http or https URL.
  def http_url?(url)
    uri = URI.parse(url.to_s)
    uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end

  private

  # Gets the page and reads its tags. It fails soft: the caller then has the URL alone.
  # @return [Hash] { title:, description:, image_url: }
  def read(url)
    response = HTTParty.get(url, headers: { "User-Agent" => USER_AGENT, "Accept" => "text/html" },
                                 timeout: READ_TIMEOUT, follow_redirects: true, limit: 5)
    return {} unless response.success?

    parse(response.body.to_s.byteslice(0, MAX_BYTES).to_s, url)
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
      image_url: absolute(meta(doc, "og:image") || meta_name(doc, "twitter:image"), url)
    }
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
