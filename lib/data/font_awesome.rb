require 'yaml'
require 'json'
require 'redis'
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
    @icons = generate_icon_data
  end

  # Saves the fetched icon data to a JSON file.
  def save_data
    File.open('data/icons.json', 'w') { |f| f << @icons.to_json }
  end

  private

  # Gathers icons data from a YAML file and fetches their SVGs from the Font Awesome GraphQL API
  # or the Redis cache, updating the cache with any missing SVGs.
  # @return [Hash] The complete icons data including families, styles, and SVG content.
  def generate_icon_data
    data = YAML.load_file('data/font_awesome.yml')
    version = data['version']
    cache_keys, icon_mappings = prepare_cache_keys_and_mappings(data['icons'], version)

    svgs_from_cache = $redis.mget(*cache_keys)
    fetch_missing_icons(svgs_from_cache, icon_mappings, version)
  end

  # Prepares the cache keys for Redis and maps those keys to their corresponding icon details.
  #
  # @param icons [Hash] The icons data from YAML file.
  # @param version [String] The version of the icons set.
  # @return [Array] Two-element array containing cache keys and icon mappings.
  def prepare_cache_keys_and_mappings(icons, version)
    cache_keys = []
    icon_mappings = {}
    icons.each do |family, styles|
      styles.each do |style, icons|
        icons.each do |icon_id|
          cache_key = cache_key_for(version, family, style, icon_id)
          cache_keys << cache_key
          icon_mappings[cache_key] = [family, style, icon_id]
        end
      end
    end
    [cache_keys, icon_mappings]
  end

  # Fetches missing SVGs from the API, updates the Redis cache, and constructs the icons data structure.
  # @param svgs_from_cache [Array] SVGs fetched from Redis cache.
  # @param icon_mappings [Hash] Mappings from cache keys to icon details.
  # @param version [String] The version of the icons set.
  # @return [Hash] The complete icons data including SVGs.
  def fetch_missing_icons(svgs_from_cache, icon_mappings, version)
    icon_data = {}
    svgs_from_cache.each_with_index do |svg, index|
      cache_key = icon_mappings.keys[index]
      family, style, icon_id = icon_mappings[cache_key]

      icon_data[family] ||= {}
      icon_data[family][style] ||= []

      svg = fetch_from_api(version, family, style, icon_id, cache_key) if svg.blank?

      icon_data[family][style] << { id: icon_id, svg: svg } if svg.present?
    end
    icon_data
  end

  # Fetches an SVG from the API and updates the Redis cache.
  # @param version [String] The version of the icon set.
  # @param family [String] The icon family.
  # @param style [String] The icon style.
  # @param icon_id [String] The unique identifier for the icon.
  # @param cache_key [String] The Redis cache key for the icon.
  # @return [String, nil] The SVG content for the icon, or nil if not found.
  def fetch_from_api(version, family, style, icon_id, cache_key)
    svg = fetch_icon_from_api(version, family, style, icon_id)
    $redis.setex(cache_key, 1.year, svg) if svg.present?
    svg
  end

  # Fetches an icon's SVG from the Font Awesome GraphQL API.
  # @param version [String] The version of the icon set.
  # @param family [String] The icon family.
  # @param style [String] The icon style.
  # @param icon_id [String] The unique identifier for the icon.
  # @return [String, nil] The SVG content for the specified icon, or nil if not found.
  def fetch_icon_from_api(version, family, style, icon_id)
    response = @client.query(FontAwesomeClient::QUERIES::Icons, variables: { version: version, query: icon_id, first: 1 })
    return if response.data.search.empty?

    icon = response.data.search.map(&:to_h).map(&:with_indifferent_access).first
    icon[:svgs].find { |s| s[:familyStyle][:family] == family && s[:familyStyle][:style] == style }&.dig(:html)
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
