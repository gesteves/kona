# Fetches articles from Contentful. `find` looks up one by entry ID (for the pageviews widget);
# `list` pulls the whole published corpus (for the request-time trending ranking). Cached in Redis.
class Articles < ApplicationService
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

  # The text + content version for one article, used to (re)compute its embedding. publishedVersion
  # bumps on every publish, so it doubles as a content fingerprint for the cached vector.
  EMBED_QUERY = <<~GRAPHQL.freeze
    query($id: String!) {
      articles: articleCollection(where: { sys: { id: $id } }, limit: 1) {
        items {
          title
          intro
          body
          sys { id publishedVersion }
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

  # One article's embedding inputs (title / intro / body / sys.published_version — the real article
  # content, which is intro+body for a full Article and intro only for a Short), fetched fresh
  # for the embedding job — not cached, since it's only called on a publish webhook and the version
  # must reflect the just-published entry. @return [OpenStruct, nil]
  def find_for_embedding(id)
    return if id.blank?

    item = rescue_with(context: "Error fetching article #{id} for embedding") do
      underscore_keys(query_articles(EMBED_QUERY, { id: id })&.first)
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

  # Pages through the whole articleCollection (best-effort: a failed page keeps the pages
  # fetched so far).
  def fetch_all
    contentful.paginate(LIST_QUERY, collection: :articles) || []
  end

  # Adds the build-time-equivalent derived fields and drops the heavy `body` (fetched only to tell
  # a full Article from a Short). The derivation lives in ArticleAttributes, shared with the
  # standard.site sync and the pageviews widget.
  def decorate(item)
    derived = ArticleAttributes.derive(
      slug: item[:slug],
      published_version: item.dig(:sys, :published_version),
      published: item[:published],
      first_published_at: item.dig(:sys, :first_published_at),
      body: item[:body]
    )

    item.except(:body).merge(derived)
  end

  # Runs a Contentful GraphQL query and returns its `articles.items`, or nil when the API isn't
  # configured or the request fails.
  def query_articles(query, variables)
    contentful.items(query, variables, collection: :articles)
  end

  def contentful
    @contentful ||= ContentfulClient.new(self.class.name)
  end
end
