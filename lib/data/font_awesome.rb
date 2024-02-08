require 'yaml'
require 'json'
require 'redis'
require 'active_support/all'
require_relative 'graphql/font_awesome'

# The FontAwesome class is responsible for fetching icon SVGs from the Font Awesome GraphQL API,
# caching them in Redis, and saving the data to a JSON file.
class FontAwesome
  # Initializes the FontAwesome object, setting up the GraphQL client
  # and Redis connection.
  def initialize
    @client = FontAwesomeClient::Client
    @redis = Redis.new(
      host: ENV['REDIS_HOST'] || 'localhost',
      port: ENV['REDIS_PORT'] || 6379,
      username: ENV['REDIS_USERNAME'],
      password: ENV['REDIS_PASSWORD']
    )
  end

  # Reads icon data from a YAML file, fetches each icon's SVG from the Font Awesome GraphQL API,
  # caches the SVGs in Redis, and saves the icon data including SVGs to a JSON file.
  def save_data
    data = YAML.load_file('data/font_awesome.yml')
    version = data['version']
    icon_data = {}

    data['icons'].each do |family, styles|
      icon_data[family] = {}

      styles.each do |style, icons|
        icon_data[family][style] = icons.map do |icon_id|
          svg = fetch_icon(version, family, style, icon_id)
          { 'id' => icon_id, 'svg' => svg }
        end
      end
    end

    File.open('data/icons.json', 'w') { |f| f << icon_data.to_json }
  end

  private

  # Fetches an icon's SVG from the Font Awesome GraphQL API or Redis cache.
  # If the SVG is not cached, it queries the API, caches the SVG, and returns it.
  # @param version [String] The version of the icon set.
  # @param family [String] The icon family (e.g., 'classic', 'solid', 'thin').
  # @param style [String] The icon style within the family (e.g., 'brands').
  # @param icon_id [String] The unique identifier for the icon.
  # @return [String] The SVG content for the specified icon.
  def fetch_icon(version, family, style, icon_id)
    cache_key = "font-awesome:v1:icon:#{version}:#{family}:#{style}:#{icon_id}"
    svg = @redis.get(cache_key)

    return svg if svg.present?

    response = @client.query(FontAwesomeClient::QUERIES::Icons, variables: { version: version, query: icon_id, first: 1 })
    icon = response.data.search.map(&:to_h).map(&:with_indifferent_access).first

    svg = icon[:svgs].find { |svg| svg[:familyStyle][:family] == family && svg[:familyStyle][:style] == style }[:html]

    @redis.setex(cache_key, 1.year, svg)

    svg
  end
end
