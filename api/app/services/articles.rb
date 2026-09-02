# Gets the articles from Contentful. `find` gets one article by its entry ID, for the pageviews
# widget. `list` gets each published article, for the trending list at request time. `corpus` gets
# the text of each one, for the lexical index of the related list. Redis caches each of the three.
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

  # The text of each article, for the lexical index of RelatedArticles.
  #
  # ⚠️ `intro` is the whole content of a Short. A Short has no body, and a Short is a correct query
  # article for the related section. Thus the index must read this field.
  CORPUS_QUERY = <<~GRAPHQL.freeze
    query($skip: Int, $limit: Int) {
      articles: articleCollection(skip: $skip, limit: $limit) {
        items {
          title
          summary
          intro
          body
          sys { id }
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
          contentfulMetadata { concepts { id } }
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

  # Each published article, with the fields that the trending list and the card render need: path,
  # entry_type, draft, and published_at. The cache holds this for 5 minutes. The edge cache is the
  # main layer for freshness, and this cache only stops many requests to Contentful at one time.
  # @return [Array<OpenStruct>]
  def list
    return @list if defined?(@list)

    items = rescue_with([], context: "Error fetching articles") do
      # A digest of the query goes at the end. Thus a change to its fields makes a new cache key,
      # and no person needs to remember to increase a version number.
      cached_json("contentful:articles:list:#{cache_version(LIST_QUERY)}", expires_in: 5.minutes) do
        fetch_all.map { |item| decorate(underscore_keys(item)) }
      end
    end

    @list = (items || []).map { |item| DeepOstruct.wrap(item) }
  end

  # The text of each article, by Contentful id, for the lexical index of RelatedArticles.
  #
  # ⚠️ This is a query of its own and it is not part of `list`, on purpose. `list` removes the body
  # and its cached value must stay small: TrendingArticles holds a full card payload below one key.
  # Only the related section reads this text, and it runs one time for each build.
  # @return [Hash{String=>Hash}] Contentful id => { title:, summary:, intro:, body: }.
  def corpus
    items = rescue_with([], context: "Error fetching the article corpus") do
      # A digest of the query goes at the end, thus a change to its fields makes a new cache key.
      cached_json("contentful:articles:corpus:#{cache_version(CORPUS_QUERY)}", expires_in: 5.minutes) do
        fetch_corpus.map { |item| underscore_keys(item) }
      end
    end

    (items || []).each_with_object({}) do |item, acc|
      id = item.dig(:sys, :id)
      acc[id] = item.slice(:title, :summary, :intro, :body) if id.present?
    end
  end

  private

  # Reads the full articleCollection, one page at a time. After a page fails, it keeps the pages
  # that it already got.
  def fetch_all
    # This is strict. Without that, a page that fails would give an incomplete set of articles, and
    # `list` would keep that set in the cache for five minutes. The related list and the trending
    # list would then omit an article that exists. AssetMirror and StandardSite are strict for the
    # same reason.
    contentful.paginate(LIST_QUERY, collection: :articles, strict: true) || []
  end

  # Reads the text of the full articleCollection. It is strict for the same reason as `fetch_all`:
  # an incomplete corpus would change the IDF of the index and stay in the cache.
  def fetch_corpus
    contentful.paginate(CORPUS_QUERY, collection: :articles, strict: true) || []
  end

  # Adds the fields that the build also makes, and removes the large `body`, which the code gets
  # only to know a full Article from a Short. ArticleAttributes makes those fields, and the
  # standard.site sync and the pageviews widget also use it.
  #
  # It also makes the nested taxonomy metadata into a flat `concept_ids` list. RelatedArticles
  # reads that list, and the flat form keeps the cached JSON small.
  def decorate(item)
    derived = ArticleAttributes.derive(
      slug: item[:slug],
      published_version: item.dig(:sys, :published_version),
      published: item[:published],
      first_published_at: item.dig(:sys, :first_published_at),
      body: item[:body]
    )

    item.except(:body, :contentful_metadata)
        .merge(derived)
        .merge(concept_ids: concept_ids(item))
  end

  # The taxonomy concept ids of one raw item.
  # @param item [Hash] The raw article, with underscore keys.
  # @return [Array<String>] The ids, or an empty list when the entry has no concept.
  def concept_ids(item)
    Array(item.dig(:contentful_metadata, :concepts)).filter_map { |concept| concept[:id].presence }
  end
end
