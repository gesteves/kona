require 'yaml'
require 'json'
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
    @icons = get_icons
  end

  # Saves the fetched icon data to a JSON file.
  def save_data
    File.open('data/icons.json', 'w') { |f| f << @icons.to_json }
  end

  private

  # Gathers icons data from a YAML file and fetches their SVGs from the Font Awesome GraphQL API
  # or the Redis cache, updating the cache with any missing SVGs.
  # @return [Hash] The complete icons data including families, styles, and SVG content.
  def get_icons
    data = YAML.load_file('data/font_awesome.yml')
    version = data['version']
    icon_metadata = get_icon_metadata(data['icons'], version)

    cache_keys = icon_metadata.keys
    svgs_from_cache = $redis.mget(*cache_keys)
    generate_icon_data(svgs_from_cache, icon_metadata, version)
  end

  # Returns a hash mapping cache keys to icon metadata
  # @param icons [Hash] The icon data from the YAML file.
  # @param version [String] The version of the icons set.
  # @return [Hash] A hash mapping cache keys to icon metadata.
  def get_icon_metadata(icons, version)
    metadata = {}
    icons.each do |family, styles|
      styles.each do |style, icons|
        icons.each do |icon_id|
          key = cache_key_for(version, family, style, icon_id)
          metadata[key] = [family, style, icon_id]
        end
      end
    end
    metadata
  end

  # Constructs the icons data structure, fetching missing SVGs from the API as needed.
  # @param svgs_from_cache [Array] SVGs fetched from Redis cache; uncached icons are nil.
  # @param icon_metadata [Hash] Hash mapping cache keys to icon details.
  # @param version [String] The version of the icons set.
  # @return [Hash] The complete icons data including SVGs.
  def generate_icon_data(svgs_from_cache, icon_metadata, version)
    icon_data = {}
    svgs_from_cache.each_with_index do |svg, index|
      key = icon_metadata.keys[index]
      family, style, icon_id = icon_metadata[key]

      icon_data[family] ||= {}
      icon_data[family][style] ||= []

      svg = fetch_from_api(version, family, style, icon_id) if svg.blank?

      icon_data[family][style] << { id: icon_id, svg: svg } if svg.present?
    end
    icon_data
  end

  # Fetches an SVG from the API and updates the Redis cache.
  # @param version [String] The version of the icon set.
  # @param family [String] The icon family.
  # @param style [String] The icon style.
  # @param icon_id [String] The unique identifier for the icon.
  # @return [String, nil] The SVG content for the icon, or nil if not found.
  def fetch_from_api(version, family, style, icon_id)
    response = @client.query(FontAwesomeClient::QUERIES::Icons, variables: { version: version, query: icon_id, first: 1 })
    return if response.data.search.empty?

    icon = response.data.search.map(&:to_h).map(&:with_indifferent_access).first
    svg = icon[:svgs].find { |s| s[:familyStyle][:family] == family && s[:familyStyle][:style] == style }&.dig(:html)

    $redis.set(cache_key_for(version, family, style, icon_id), svg) if svg.present?
    svg
  end

  # Constructs a Redis cache key for an icon.
  # @param version [String] The version of the icon set.
  # @param family [String] The icon family.
  # @param style [String] The icon style.
  # @param icon_id [String] The unique identifier for the icon.
  # @return [String] The constructed cache key for the icon.
  def cache_key_for(version, family, style, icon_id)
    "font-awesome:icon:#{version}:#{family}:#{style}:#{icon_id}"
  end
end
