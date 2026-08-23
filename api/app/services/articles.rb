# Gets the articles from Contentful. `find` gets one article by its entry ID, for the pageviews
# widget. `list` gets each published article, for the trending list at request time. Redis caches
# both.
class Articles < ApplicationService
  include ContentfulConsumer

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

  # The text and the content version of one article, to calculate its embedding. publishedVersion
  # increases at each publish, thus it is also a content fingerprint for the cached vector.
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
          coverImage {
            url
            width
            height
            contentType
            sys { id publishedVersion }
          }
          sys { id firstPublishedAt publishedVersion }
        }
      }
    }
  GRAPHQL

  # @return [OpenStruct, nil]
  def find(id)
    find_cached_item(id, query: FIND_QUERY, collection: :articles,
                         cache_key: "contentful:article", context: "Error fetching article #{id}")
  end

  # The embedding inputs of one article: the title, the intro, the body, and sys.published_version.
  # The true article content is the intro and the body for a full Article, and the intro only for a
  # Short. The code gets this again for the embedding job. No cache holds it, because a publish
  # webhook is the only caller and the version must be the version of the new entry.
  # @return [OpenStruct, nil]
  def find_for_embedding(id)
    return if id.blank?

    item = rescue_with(context: "Error fetching article #{id} for embedding") do
      underscore_keys(query_articles(EMBED_QUERY, { id: id })&.first)
    end

    item && DeepOstruct.wrap(item)
  end

  # Each published article, with the fields that the trending list and the card render need: path,
  # entry_type, draft, and published_at. The cache holds this for 5 minutes. The edge cache is the
  # main layer for freshness, and this cache only stops many requests to Contentful at one time.
  # @return [Array<OpenStruct>]
  def list
    items = rescue_with([], context: "Error fetching articles") do
      # A digest of the query goes at the end. Thus a change to its fields makes a new cache key,
      # and no person needs to remember to increase a version number.
      cached_json("contentful:articles:list:#{cache_version(LIST_QUERY)}", expires_in: 5.minutes) do
        fetch_all.map { |item| decorate(underscore_keys(item)) }
      end
    end

    (items || []).map { |item| DeepOstruct.wrap(item) }
  end

  private

  # Reads the full articleCollection, one page at a time. After a page fails, it keeps the pages
  # that it already got.
  def fetch_all
    # This is strict. Without that, a page that fails would give an incomplete set of articles, and
    # `list` would keep that set in the cache for five minutes. embeddings:backfill reads through
    # it, thus it would add too few jobs against a set that looked complete. AssetMirror and
    # StandardSite are strict for the same reason.
    contentful.paginate(LIST_QUERY, collection: :articles, strict: true) || []
  end

  # Adds the fields that the build also makes, and removes the large `body`, which the code gets
  # only to know a full Article from a Short. ArticleAttributes makes those fields, and the
  # standard.site sync and the pageviews widget also use it.
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

  # Does a Contentful GraphQL query and returns its `articles.items`, or nil if there is no API
  # configuration or the request fails.
  def query_articles(query, variables)
    contentful.items(query, variables, collection: :articles)
  end
end
