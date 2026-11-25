require "active_support/core_ext/object/blank"

# Gets the SVG of a Font Awesome icon and puts it in Redis. An icon does not change in one version,
# thus the cache holds each SVG for a year. That is long enough to keep the cache warm, and it has a
# limit, thus an icon from an older version does not stay for all time.
class FontAwesome
  DEFAULT_VERSION = "7.3.0"
  CACHE_TTL = 1.year
  # A true miss, where the API answered but no icon matched, goes into the cache as an empty string.
  # Thus an icon id in a view with a typing error, or with a new name, does not cause a GraphQL
  # search at each render. The time is short, thus a corrected id, or a new Font Awesome release,
  # works again quickly.
  MISS_CACHE_TTL = 1.hour

  # The SVG markup of an icon. It comes from Redis if the cache has it, and from the Font Awesome
  # API if the cache does not.
  # @param family [String] The Font Awesome family of the icon, for example "classic".
  # @param style [String] The style of the icon in that family, for example "light".
  # @param icon_id [String] The identifier of the icon, for example "person-running".
  # @return [String, nil] The SVG markup, or nil if the code cannot find the icon.
  def svg(family, style, icon_id)
    version = ENV["FONT_AWESOME_VERSION"].presence || DEFAULT_VERSION
    cached = $redis.get(cache_key_for(version, family, style, icon_id))
    return cached.presence unless cached.nil? # "" is the cached-miss sentinel

    fetch_from_api(version, family, style, icon_id)
  end

  private

  # Gets an SVG from the Font Awesome GraphQL API and puts it in Redis. The cache also holds a miss.
  # It holds no temporary API failure.
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
