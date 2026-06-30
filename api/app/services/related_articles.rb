# Ranks the "You May Also Like" widget at request time by semantic similarity, replacing the
# build-time tag/title heuristic the static site used. Each published article has a Voyage embedding
# precomputed by ArticleEmbeddingJob (webhook-driven) and cached in Redis; here we load the current
# article's vector plus every candidate's, score them by cosine similarity, and return the nearest
# neighbors (recency breaks ties). The ranking is computed once per article and cached briefly. The
# request path never calls Voyage — it only reads stored vectors and does the arithmetic.
class RelatedArticles < ApplicationService
  # Cache (and serve) only the top slice of the ranking — plenty to fill the widget, while bounding
  # the JSON we cache. Keyed per article, unlike trending's single shared ranking.
  MAX_POOL = 12
  # The neighbors of an article change only when the corpus or its embeddings change, so memoize
  # briefly (mirrors TrendingArticles::RESULT_TTL).
  RESULT_TTL = 10.minutes

  # @param articles [Articles] corpus source (injectable for testing)
  def initialize(articles: Articles.new)
    @articles = articles
  end

  # The top `count` articles most semantically related to the article with Contentful id `id`.
  # @return [Array<OpenStruct>]
  def for_article(id, count: 4)
    ranked(id).first(count)
  end

  private

  # The ranked neighbor list (corpus DeepOstructs, nearest first), cached per article. Degrades to an
  # empty list (→ render_empty) when the article has no stored vector or on any error.
  def ranked(id)
    return [] if id.blank?

    rescue_with([], context: self.class.name) do
      items = cached_json("related:articles:ranked:#{id}:v1", expires_in: RESULT_TTL) do
        rank(id).map { |article| payload(article) }
      end
      (items || []).map { |item| DeepOstruct.wrap(item) }
    end
  end

  # Scores every candidate against the current article's vector by cosine similarity. Candidates with
  # no stored vector yet (e.g. published before their embedding job ran) are skipped, not zero-scored.
  def rank(id)
    query_vector = load_vector(id)
    return [] if query_vector.blank?

    pool = candidates(id)
    return [] if pool.blank?

    vectors = load_vectors(pool.map { |article| article.sys&.id })

    scored = pool.filter_map do |article|
      vector = vectors[article.sys&.id]
      next if vector.blank?
      { article: article, score: cosine(query_vector, vector), published: DateTime.parse(article.published_at) }
    end

    scored
      .sort_by { |e| [-e[:score], -e[:published].to_time.to_i] }
      .first(MAX_POOL)
      .map { |e| e[:article] }
  end

  # Published, non-Short articles with a resolvable path, minus the current article (matches the
  # trending candidate set; the current article is the only id-based exclusion).
  def candidates(id)
    @articles.list.reject { |a| a.draft || a.entry_type == "Short" || a.path.blank? || a.sys&.id == id }
  end

  # The current article's stored embedding vector (nil when it hasn't been embedded yet).
  def load_vector(id)
    parse_vector($redis.get(ArticleEmbeddingJob.redis_key(id)))
  end

  # One Redis round trip for the whole candidate pool → { id => vector|nil }.
  def load_vectors(ids)
    ids = ids.compact
    return {} if ids.empty?
    raw = $redis.mget(*ids.map { |id| ArticleEmbeddingJob.redis_key(id) })
    ids.zip(raw).to_h { |id, json| [id, parse_vector(json)] }
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

  # The fields the card view renders, so the cached ranking is self-contained (mirrors
  # TrendingArticles#payload).
  def payload(article)
    {
      title: article.title,
      summary: article.summary,
      slug: article.slug,
      path: article.path,
      published_at: article.published_at,
      entry_type: article.entry_type,
      draft: article.draft,
      sys: { id: article.sys&.id }
    }
  end
end
