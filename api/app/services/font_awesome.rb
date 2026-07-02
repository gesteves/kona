require "active_support/core_ext/object/blank"

# Fetches Font Awesome icon SVGs, caching them in Redis. Icons are immutable for a
# given version, so cached SVGs are cached for a year — long enough to stay warm, but
# bounded so icons from a superseded version don't linger forever.
class FontAwesome
  DEFAULT_VERSION = "7.3.0"
  CACHE_TTL = 1.year
  # Definitive misses (the API answered, but no icon matched) are cached as an empty-string
  # sentinel so a mistyped/renamed icon id in a view doesn't trigger a GraphQL search on
  # every render. Kept short so a fixed id (or a new FA release) recovers quickly.
  MISS_CACHE_TTL = 1.hour

  # Returns the SVG markup for an icon, from Redis if cached or the Font Awesome API otherwise.
  # @param family [String] The icon's Font Awesome family (e.g., "classic").
  # @param style [String] The icon's style within the family (e.g., "light").
  # @param icon_id [String] The icon's identifier (e.g., "person-running").
  # @return [String, nil] The SVG markup, or nil if not found.
  def svg(family, style, icon_id)
    version = ENV["FONT_AWESOME_VERSION"].presence || DEFAULT_VERSION
    cached = $redis.get(cache_key_for(version, family, style, icon_id))
    return cached.presence unless cached.nil? # "" is the cached-miss sentinel

    fetch_from_api(version, family, style, icon_id)
  end

  private

  # Fetches an SVG from the Font Awesome GraphQL API and caches it in Redis (misses are
  # negatively cached; transient API failures are not cached at all).
  # @see https://fontawesome.com/docs/apis/graphql/get-started
  def fetch_from_api(version, family, style, icon_id)
    response = FontAwesomeClient.client.query(FontAwesomeClient.icons_query, variables: { version: version, query: icon_id })
    return if response.data.nil?

    results = response.data.search.map(&:to_h)
    icon = results.find { |i| i["id"] == icon_id }
    svg = icon&.dig("svgs")&.find { |s| s.dig("familyStyle", "family") == family && s.dig("familyStyle", "style") == style }&.dig("html")
    if svg.present?
      $redis.setex(cache_key_for(version, family, style, icon_id), CACHE_TTL, svg)
    else
      $redis.setex(cache_key_for(version, family, style, icon_id), MISS_CACHE_TTL, "")
    end
    svg
  rescue StandardError => e
    Rails.logger.error("Error fetching Font Awesome icon #{icon_id}: #{e}")
    ErrorReporter.report_upstream(e, service: "FontAwesome", context: "Font Awesome icon #{icon_id}")
    nil
  end

  def cache_key_for(version, family, style, icon_id)
    "font-awesome:icon:#{version}:#{family}:#{style}:#{icon_id}"
  end
end
