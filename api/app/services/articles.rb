# Fetches a single article from Contentful by its entry ID — just the fields needed to
# rebuild the article's path (slug + publish date) for the Plausible pageviews lookup.
# Cached in Redis for an hour.
class Articles < ApplicationService
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

    item = rescue_with(context: "Error fetching article #{id}") do
      cached_json("contentful:article:#{id}", expires_in: 1.hour) do
        space = ENV["CONTENTFUL_SPACE"]
        token = ENV["CONTENTFUL_TOKEN"]
        next if space.blank? || token.blank?

        data = post_json(
          "#{CONTENTFUL_API_URL}/#{space}",
          body: { query: FIND_QUERY, variables: { id: id } }.to_json,
          headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
        )
        underscore_keys(data&.dig(:data, :articles, :items)&.first)
      end
    end

    item && DeepOstruct.wrap(item)
  end
end
