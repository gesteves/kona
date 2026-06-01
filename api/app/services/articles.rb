# Fetches articles from Contentful. `find` looks up one by entry ID (for the pageviews widget);
# `list` pulls the whole published corpus (for the request-time trending ranking). Cached in Redis.
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

  LIST_QUERY = <<~GRAPHQL.freeze
    query($skip: Int, $limit: Int) {
      articles: articleCollection(skip: $skip, limit: $limit) {
        items {
          title
          slug
          summary
          published
          body
          sys { id firstPublishedAt publishedVersion }
        }
      }
    }
  GRAPHQL

  PAGE_SIZE = 100

  # @return [OpenStruct, nil]
  def find(id)
    return if id.blank?

    item = rescue_with(context: "Error fetching article #{id}") do
      cached_json("contentful:article:#{id}", expires_in: 5.minutes) do
        underscore_keys(query_articles(FIND_QUERY, { id: id })&.first)
      end
    end

    item && DeepOstruct.wrap(item)
  end

  # The full published-article corpus, decorated with the derived fields the trending ranking and
  # card rendering need (path / entry_type / draft / published_at). Cached for 5 minutes — the
  # edge cache is the primary freshness layer; this just guards Contentful against a stampede.
  # @return [Array<OpenStruct>]
  def list
    items = rescue_with([], context: "Error fetching articles") do
      cached_json("contentful:articles:list:v1", expires_in: 5.minutes) do
        fetch_all.map { |item| decorate(underscore_keys(item)) }
      end
    end

    (items || []).map { |item| DeepOstruct.wrap(item) }
  end

  private

  # Pages through the whole articleCollection (the delivery API returns published entries only).
  def fetch_all
    all = []
    skip = 0
    loop do
      items = query_articles(LIST_QUERY, { skip: skip, limit: PAGE_SIZE })
      break if items.blank?
      all.concat(items)
      break if items.size < PAGE_SIZE
      skip += PAGE_SIZE
    end
    all
  end

  # Adds the build-time-equivalent derived fields and drops the heavy `body` (fetched only to tell
  # a full Article from a Short). Mirrors web's set_entry_type / set_draft_status / set_article_path.
  def decorate(item)
    draft = item.dig(:sys, :published_version).blank?
    published_at = item[:published].presence || item.dig(:sys, :first_published_at)
    entry_type = item[:body].present? ? "Article" : "Short"
    path = if !draft && item[:slug].present? && published_at.present?
      d = DateTime.parse(published_at)
      "/#{d.strftime('%Y/%m/%d')}/#{item[:slug]}/"
    end

    item.except(:body).merge(draft: draft, entry_type: entry_type, published_at: published_at, path: path)
  end

  # Runs a Contentful GraphQL query and returns its `articles.items`, or nil when the API isn't
  # configured or the request fails.
  def query_articles(query, variables)
    space = ENV["CONTENTFUL_SPACE"]
    token = ENV["CONTENTFUL_TOKEN"]
    return if space.blank? || token.blank?

    data = post_json(
      "#{CONTENTFUL_API_URL}/#{space}",
      body: { query: query, variables: variables }.to_json,
      headers: { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
    )
    data&.dig(:data, :articles, :items)
  end
end
