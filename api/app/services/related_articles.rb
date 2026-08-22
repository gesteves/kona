# Puts the articles of the "You May Also Like" widget in order by the similarity of their meaning.
# It loads the Voyage embedding of the current article and of each candidate, gives each candidate
# a score from the cosine similarity, and returns the nearest ones. The date selects between two
# equal scores. The request path never calls Voyage: ArticleEmbeddingJob stores the vectors, and
# this class only reads them and does the arithmetic.
class RelatedArticles < ApplicationService
  include ArticleRanking # candidates + payload, shared with TrendingArticles

  # The part of the list that the cache holds. It is enough to fill the widget, and it keeps the
  # cached JSON small. There is one key for each article. The trending list is different: it has
  # one shared list.
  MAX_POOL = 12
  # The neighbors change only when the articles or their embeddings change, thus the code can keep
  # the value for a short time.
  RESULT_TTL = 10.minutes

  # @param articles [Articles] The source of the articles. A test can supply its own.
  def initialize(articles: Articles.new)
    @articles = articles
  end

  # @param id [String] The Contentful id of the article.
  # @return [Array<OpenStruct>] The `count` articles with the nearest meaning to it.
  def for_article(id, count: 4)
    ranked(id).first(count)
  end

  # The nearest neighbors of each entry, for the static "You May Also Like" section of the web
  # build. This reads the articles one time, and not one time for each article: the vectors come in
  # one request and the rest is arithmetic.
  #
  # ⚠️ No cache holds this, and `for_article` is different. The build calls this one time,
  # immediately after a publish. That is the one moment when a list from ten minutes ago would be
  # wrong, because it would omit the entry that started the build. The slow part, which is the
  # embeddings, is already in the cache.
  #
  # ⚠️ There is a key for each published entry, and not only for each candidate. A Short is a
  # correct query article, because the section appears on its own page, but a Short can never be a
  # neighbor. `for_article` does the same, and it never needed the query id to be a candidate.
  # @param count [Integer] The number of neighbors for each entry.
  # @return [Hash{String=>Array<String>}] Contentful id => the neighbor ids, the nearest first. An
  #   entry with no stored vector is absent, and not empty.
  def all(count: 4)
    rescue_with({}, context: self.class.name) do
      pool = candidates
      published = @articles.list.reject(&:draft)
      vectors = load_vectors((published + pool).map { |article| article.sys&.id }.uniq)

      published.each_with_object({}) do |article, acc|
        id = article.sys&.id
        query_vector = vectors[id]
        next if id.blank? || query_vector.blank?

        neighbors = neighbors_for(id, query_vector, pool, vectors, count)
        acc[id] = neighbors if neighbors.present?
      end
    end
  end

  private

  # Gives each candidate a score against one query vector. The order is the same as in `rank`: the
  # nearest first, and the date selects between two equal scores. Thus the static section and the
  # widget agree.
  # @return [Array<String>] The ids of the nearest neighbors, but not the query article.
  def neighbors_for(id, query_vector, pool, vectors, count)
    scored = pool.filter_map do |article|
      other_id = article.sys&.id
      next if other_id.blank? || other_id == id

      vector = vectors[other_id]
      next if vector.blank?

      { id: other_id, score: cosine(query_vector, vector), published: DateTime.parse(article.published_at) }
    end

    scored
      .sort_by { |e| [ -e[:score], -e[:published].to_time.to_i ] }
      .first(count)
      .map { |e| e[:id] }
  end

  # The neighbors in order, the nearest first. There is one cache entry for each article. It is
  # empty when the article has no stored vector, and on an error, and the widget then goes away.
  def ranked(id)
    return [] if id.blank?

    rescue_with([], context: self.class.name) do
      items = cached_json("related:articles:ranked:#{id}:#{cache_version(PAYLOAD_VERSION)}", expires_in: RESULT_TTL) do
        rank(id).map { |article| payload(article) }
      end
      (items || []).map { |item| DeepOstruct.wrap(item) }
    end
  end

  # Gives each candidate a score from the cosine similarity. The code omits a candidate with no
  # stored vector, and it does not give that candidate a score of zero.
  def rank(id)
    query_vector = load_vector(id)
    return [] if query_vector.blank?

    # The shared set of candidates, but not the current article.
    pool = candidates.reject { |article| article.sys&.id == id }
    return [] if pool.blank?

    vectors = load_vectors(pool.map { |article| article.sys&.id })

    scored = pool.filter_map do |article|
      vector = vectors[article.sys&.id]
      next if vector.blank?
      { article: article, score: cosine(query_vector, vector), published: DateTime.parse(article.published_at) }
    end

    scored
      .sort_by { |e| [ -e[:score], -e[:published].to_time.to_i ] }
      .first(MAX_POOL)
      .map { |e| e[:article] }
  end

  # The stored embedding vector of the current article. It is nil when the article has none.
  def load_vector(id)
    parse_vector($redis.get(ArticleEmbeddingJob.redis_key(id)))
  end

  # @return [Hash] { id => vector or nil } for each candidate, in one request.
  def load_vectors(ids)
    ids = ids.compact
    return {} if ids.empty?
    raw = $redis.mget(*ids.map { |id| ArticleEmbeddingJob.redis_key(id) })
    ids.zip(raw).to_h { |id, json| [ id, parse_vector(json) ] }
  end

  # Gets the vector from a stored `{ version:, vector: }` JSON value.
  def parse_vector(json)
    return if json.blank?
    JSON.parse(json)["vector"]
  rescue JSON::ParserError
    nil
  end

  # The cosine similarity of two vectors of the same length. It is 0 when an input is blank, when
  # the two lengths are different, or when a norm is zero.
  def cosine(a, b)
    return 0.0 if a.blank? || b.blank? || a.size != b.size

    dot = norm_a = norm_b = 0.0
    a.each_index do |i|
      dot += a[i] * b[i]
      norm_a += a[i]**2
      norm_b += b[i]**2
    end
    return 0.0 if norm_a.zero? || norm_b.zero?

    dot / (Math.sqrt(norm_a) * Math.sqrt(norm_b))
  end
end
