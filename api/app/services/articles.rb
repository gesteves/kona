require "httparty"

# Fetches a single article from Contentful by its entry ID — just the fields needed to
# rebuild the article's path (slug + publish date) for the Plausible pageviews lookup.
# Cached in Redis for an hour.
class Articles
  CONTENTFUL_API_URL = "https://graphql.contentful.com/content/v1/spaces"
  FIND_QUERY = <<~GRAPHQL.freeze
    query($id: String!) {
      articles: articleCollection(where: { sys: { id: $id } }, limit: 1) {
        items {
          slug
          published
          sys { id firstPublishedAt }
        }
      }
    }
  GRAPHQL

  # @return [OpenStruct, nil]
  def find(id)
    return if id.blank?

    key = "contentful:article:#{id}"
    cached = $redis.get(key)
    return DeepOstruct.wrap(JSON.parse(cached, symbolize_names: true)) if cached.present?

    space = ENV["CONTENTFUL_SPACE"]
    token = ENV["CONTENTFUL_TOKEN"]
    return if space.blank? || token.blank?

    response = HTTParty.post(
      "#{CONTENTFUL_API_URL}/#{space}",
      body: { query: FIND_QUERY, variables: { id: id } }.to_json,
      headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
    )
    return unless response.success?

    item = JSON.parse(response.body, symbolize_names: true).dig(:data, :articles, :items)&.first
    return if item.blank?

    item = item.deep_transform_keys { |key| key.to_s.underscore.to_sym }
    $redis.setex(key, 1.hour, item.to_json)
    DeepOstruct.wrap(item)
  rescue StandardError => e
    Rails.logger.error("Error fetching article #{id}: #{e}")
    nil
  end
end
