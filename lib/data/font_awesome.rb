require 'active_support/all'
require_relative 'graphql/font_awesome'

# The FontAwesome class fetches icon SVGs from the Font Awesome GraphQL API, caches them in Redis,
# and saves the data to a JSON file.
class FontAwesome
  # Initializes the FontAwesome object by setting up the GraphQL client
  # and fetching the icons data.
  # @return [FontAwesome] instance of the FontAwesome class.
  def initialize
    @client = FontAwesomeClient::Client
    @version = ENV['FONT_AWESOME_VERSION']
  end

  # Fetches an icon from the Font Awesome GraphQL API.
  # @param family [String] The icon family.
  # @param style [String] The icon style.
  # @param icon_id [String] The unique identifier for the icon.
  # @return [String, nil] The SVG content for the icon, or nil if not found.
  def get_icon(family, style, icon_id)
    return if family.blank? || style.blank? || icon_id.blank?

    cache_key = cache_key_for(family, style, icon_id)
    svg = $redis.get(cache_key)
    return svg if svg.present?

    svg = fetch_from_api(family, style, icon_id)
    $redis.set(cache_key, svg) if svg.present?
    svg
  end

  private

  # Fetches an SVG from the API and updates the Redis cache.
  # @param family [String] The icon family.
  # @param style [String] The icon style.
  # @param icon_id [String] The unique identifier for the icon.
  # @see https://fontawesome.com/docs/apis/graphql/get-started
  # @return [String, nil] The SVG content for the icon, or nil if not found.
  def fetch_from_api(family, style, icon_id)
    response = @client.query(FontAwesomeClient::QUERIES::Icons, variables: { version: @version, query: icon_id })
    return if response.data.search.empty?

    results = response.data.search.map(&:to_h)
    icon = results.find { |i| i['id'] == icon_id }
    return if icon.blank?
    icon.dig('svgs')&.find { |s| s.dig('familyStyle', 'family') == family && s.dig('familyStyle', 'style') == style }&.dig('html')
  end

  # Constructs a Redis cache key for an icon.
  # @param family [String] The icon family.
  # @param style [String] The icon style.
  # @param icon_id [String] The unique identifier for the icon.
  # @return [String] The constructed cache key for the icon.
  def cache_key_for(family, style, icon_id)
    "font-awesome:icon:#{@version}:#{family}:#{style}:#{icon_id}"
  end
end
