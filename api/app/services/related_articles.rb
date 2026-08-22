# Ranks the "You May Also Like" widget by semantic similarity: loads the current article's
# precomputed Voyage embedding plus every candidate's, scores them by cosine similarity, and
# returns the nearest neighbors, with recency breaking ties. The request path never calls Voyage
# — ArticleEmbeddingJob stores the vectors, and this only reads them and does the arithmetic.
class RelatedArticles < ApplicationService
  include ArticleRanking # candidates + payload, shared with TrendingArticles

  # How much of the ranking to cache: plenty to fill the widget, while bounding the cached JSON.
  # Keyed per article, unlike trending's single shared ranking.
  MAX_POOL = 12
  # Neighbors change only when the corpus or its embeddings do, so this can memoize briefly.
  RESULT_TTL = 10.minutes

  # @param articles [Articles] The corpus source; injectable for testing.
  def initialize(articles: Articles.new)
    @articles = articles
  end

  # @param id [String] The article's Contentful id.
  # @return [Array<OpenStruct>] The `count` articles most semantically related to it.
  def for_article(id, count: 4)
    ranked(id).first(count)
  end

  # Every entry's nearest neighbors, for the web build's static "You May Also Like" section.
  # One pass over the corpus rather than one request per article: the vectors load in a single
  # round trip and the rest is arithmetic.
  #
  # ⚠️ Uncached, unlike `for_article`. This is called once per build, right after a publish —
  # the one moment a ten-minute-old ranking would be wrong, since it would omit the entry that
  # triggered the build. The expensive part (the embeddings themselves) is already cached.
  #
  # ⚠️ Keyed by every published entry, not just the candidates: a Short is a valid query
  # article — it gets the section on its own page — even though it can never be a neighbor.
  # `for_article` behaves the same way, having never required the query id to be a candidate.
  # @param count [Integer] How many neighbors per entry.
  # @return [Hash{String=>Array<String>}] Contentful id => neighbor ids, nearest first. An entry
  #   with no stored vector is absent rather than empty.
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

  # Scores one query vector against the candidate pool. Same ordering as `rank` — nearest
  # first, recency breaking ties — so the static section and the widget agree.
  # @return [Array<String>] The nearest neighbor ids, excluding the query article itself.
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

  # The ranked neighbors, nearest first, cached per article. Empty when the article has no
  # stored vector or on any error, which collapses the widget.
  def ranked(id)
    return [] if id.blank?

    rescue_with([], context: self.class.name) do
      items = cached_json("related:articles:ranked:#{id}:#{cache_version(PAYLOAD_VERSION)}", expires_in: RESULT_TTL) do
        rank(id).map { |article| payload(article) }
      end
      (items || []).map { |item| DeepOstruct.wrap(item) }
    end
  end

  # Scores every candidate by cosine similarity. Candidates with no stored vector yet are
  # skipped rather than zero-scored.
  def rank(id)
    query_vector = load_vector(id)
    return [] if query_vector.blank?

    # The shared candidate set, minus the current article.
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

  # The current article's stored embedding vector (nil when it hasn't been embedded yet).
  def load_vector(id)
    parse_vector($redis.get(ArticleEmbeddingJob.redis_key(id)))
  end

  # @return [Hash] { id => vector or nil } for the whole candidate pool, in one round trip.
  def load_vectors(ids)
    ids = ids.compact
    return {} if ids.empty?
    raw = $redis.mget(*ids.map { |id| ArticleEmbeddingJob.redis_key(id) })
    ids.zip(raw).to_h { |id, json| [ id, parse_vector(json) ] }
  end

  # Pulls the vector out of a stored `{ version:, vector: }` JSON blob.
  def parse_vector(json)
    return if json.blank?
    JSON.parse(json)["vector"]
  rescue JSON::ParserError
    nil
  end

  # Cosine similarity of two equal-length vectors; 0 for blank/mismatched/zero-norm inputs.
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
