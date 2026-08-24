# Puts the articles of the "You May Also Like" section in order. It reads the Voyage embedding of
# each article, gives each candidate a score, and returns the nearest ones. The request path never
# calls Voyage: ArticleEmbeddingJob stores the vectors, and this class only reads them and does the
# arithmetic.
#
# The score of one candidate has two parts:
#   * relevance = (TAXONOMY_WEIGHT · concept overlap + (1 - TAXONOMY_WEIGHT) · vector similarity),
#                 with a demotion when the candidate reports the same race as the query article.
#   * score     = relevance + a small addition for a recent article and for one that people read.
#
# A floor over the **relevance** removes each candidate that is not truly related. The score then
# puts the survivors in order, and MMR selects the final list.
class RelatedArticles < ApplicationService
  include ArticleRanking # candidates, shared with TrendingArticles

  # The weight of the concept overlap. The vector similarity gets the rest.
  TAXONOMY_WEIGHT = ENV.fetch("RELATED_TAXONOMY_WEIGHT", 0.25).to_f
  # The balance of MMR: 1.0 is relevance only, and 0.0 is diversity only.
  MMR_LAMBDA = ENV.fetch("RELATED_MMR_LAMBDA", 0.7).to_f
  # The floor, in standard deviations above the mean relevance of that query.
  FLOOR_SIGMAS = ENV.fetch("RELATED_FLOOR_SIGMAS", 0.5).to_f
  # ⚠️ The absolute part of the floor, and the reason that a section can render nothing. After the
  # mean subtraction, the mean similarity of a pair is near 0. Thus a positive score means "these
  # two are more alike than two articles of this corpus usually are", and a score at or below 0
  # means that the candidate is not truly related. A floor in standard deviations alone can never
  # empty a list, because it always keeps the best part of the distribution.
  MIN_SCORE = 0.0
  # The candidates that go into MMR. A larger pool gives MMR more to select from, and it costs one
  # similarity for each pair inside the pool.
  MMR_POOL = 24
  # The largest addition from the date and the popularity. It is small, thus it moves only a
  # near-equal pair and it never wins against the topic.
  PRIOR_WEIGHT = 0.02
  # The age at which the addition for the date is one half of its value, in days.
  AGE_HALF_LIFE_DAYS = 730.0
  # The factor that a candidate of the same race gets. MMR does most of this work, because four
  # reports of the same race are near-copies of each other and MMR takes one of them.
  SAME_RACE_FACTOR = 0.85

  # @param articles [Articles] The source of the articles. A test can supply its own.
  # @param plausible [Plausible] The source of the analytics. A test can supply its own.
  # @param taxonomy [TaxonomyConcepts] The source of the concept tree. A test can supply its own.
  def initialize(articles: Articles.new, plausible: Plausible.new, taxonomy: TaxonomyConcepts.new)
    @articles = articles
    @plausible = plausible
    @taxonomy = taxonomy
  end

  # The nearest neighbors of each entry, for the static "You May Also Like" section of the web
  # build. This reads the articles one time, and not one time for each article: the vectors come in
  # one request and the rest is arithmetic.
  #
  # ⚠️ No cache holds this. The build calls it one time, immediately after a publish. That is the
  # one moment when a list from ten minutes ago would be wrong, because it would omit the entry
  # that started the build. The slow part, which is the embeddings, is already in the cache.
  #
  # ⚠️ There is a key for each published entry, and not only for each candidate. A Short is a
  # correct query article, because the section appears on its own page, but a Short can never be a
  # neighbor.
  #
  # ⚠️ An entry with a vector always gets a key, and its list is empty when no candidate goes past
  # the floor. An entry with **no vector** is absent. Thus the key says "this entry has an
  # embedding", and `report_related_coverage` in the web build can tell a missing embedding from a
  # floor that removed each candidate. Those two look the same, and only one of them is a problem.
  # @param count [Integer] The number of neighbors for each entry.
  # @return [Hash{String=>Array<String>}] Contentful id => the neighbor ids, the nearest first.
  def all(count: 4)
    rescue_with({}, context: self.class.name) do
      pool = candidates
      published = @articles.list.reject(&:draft)
      next {} if pool.blank? || published.blank?

      context = build_context(published, pool)

      published.each_with_object({}) do |article, acc|
        id = article.sys&.id
        next if id.blank? || context[:vectors][id].blank?

        acc[id] = neighbors_for(article, pool, context, count)
      end
    end
  end

  # The full score of each candidate against one article, for `rake related:inspect`. It uses the
  # same methods as `all`, thus the report can never describe a different ranking.
  # @param id [String] The Contentful id of the query article.
  # @param count [Integer] The number of neighbors that the section shows.
  # @return [Hash, nil] { floor:, rows: }, or nil when the corpus or the vector is absent.
  def explain(id, count: 4)
    pool = candidates
    published = @articles.list.reject(&:draft)
    return if pool.blank? || published.blank?

    article = published.find { |a| a.sys&.id == id }
    return if article.nil?

    context = build_context(published, pool, detailed: true)
    return if context[:vectors][id].blank?

    scored = score_rows(article, pool, context)
    floor = floor_for(scored)
    survivors = scored.select { |row| above_floor?(row, floor) }.sort_by { |row| -row[:score] }.first(MMR_POOL)
    selected = select_by_mmr(survivors, count).map { |row| row[:id] }.to_set

    rows = scored.sort_by { |row| -row[:score] }.map do |row|
      row.except(:vector).merge(above_floor: above_floor?(row, floor), selected: selected.include?(row[:id]))
    end

    { floor: floor, rows: rows }
  end

  private

  # Everything that each query article reads: the prepared vectors, the taxonomy scorer, the
  # popularity, and the race of each candidate. The code makes it one time for the full corpus.
  # @param detailed [Boolean] True to keep the vectors with no mean subtraction, for the report.
  def build_context(published, pool, detailed: false)
    ids = (published + pool).filter_map { |article| article.sys&.id }.uniq
    taxonomy = ArticleTaxonomy.new(articles: published, tree: taxonomy_tree)
    raw = load_vectors(ids)

    {
      vectors: ArticleSimilarity.prepare(raw),
      raw: detailed ? raw.transform_values { |v| v && ArticleSimilarity.unit(v) } : nil,
      titles: published.each_with_object({}) { |a, acc| acc[a.sys&.id] = a.title },
      taxonomy: taxonomy,
      # ⚠️ One time for each article, and not one time for each pair. This loop compares each
      # article against each other article.
      races: published.each_with_object({}) { |a, acc| acc[a.sys&.id] = taxonomy.race_concept_id(a) },
      priors: priors(pool)
    }
  end

  # Gives each candidate a score against one query article, removes the candidates below the floor,
  # and lets MMR select the final list.
  # @return [Array<String>] The ids of the neighbors, the nearest first.
  def neighbors_for(article, pool, context, count)
    scored = score_rows(article, pool, context)
    floor = floor_for(scored)
    survivors = scored.select { |row| above_floor?(row, floor) }.sort_by { |row| -row[:score] }.first(MMR_POOL)

    select_by_mmr(survivors, count).map { |row| row[:id] }
  end

  # The score of each candidate against one query article.
  # @return [Array<Hash>] One row for each candidate with a vector.
  def score_rows(article, pool, context)
    id = article.sys&.id
    query_vector = context[:vectors][id]
    query_race = context[:races][id]

    pool.filter_map do |candidate|
      other_id = candidate.sys&.id
      next if other_id.blank? || other_id == id

      vector = context[:vectors][other_id]
      next if vector.blank?

      centered = ArticleSimilarity.similarity(query_vector, vector)
      overlap = context[:taxonomy].overlap(id, other_id)
      penalty = same_race_penalty(other_id, query_race, context)
      relevance = (((1.0 - TAXONOMY_WEIGHT) * centered) + (TAXONOMY_WEIGHT * overlap)) * penalty

      {
        id: other_id,
        title: context[:titles][other_id],
        raw: context[:raw] ? ArticleSimilarity.similarity(context[:raw][id], context[:raw][other_id]) : 0.0,
        centered: centered,
        overlap: overlap,
        relevance: relevance,
        score: relevance + context[:priors][other_id].to_f,
        vector: vector
      }
    end
  end

  # ⚠️ This is a demotion and never an exclusion. A Short renders the related section with no
  # "More Reports From This Race" section above it. Thus a neighbor of the same race must stay
  # available there. The build removes a true repeat by itself.
  def same_race_penalty(other_id, query_race, context)
    return 1.0 if query_race.blank?
    context[:races][other_id] == query_race ? SAME_RACE_FACTOR : 1.0
  end

  # The larger of two floors: the mean relevance plus FLOOR_SIGMAS standard deviations, and
  # MIN_SCORE. Each candidate below it is not truly related. Thus an article with no true neighbor
  # gives a short list, or none, and the section then renders nothing.
  #
  # ⚠️ The floor reads the relevance and not the score, on purpose. The score holds the addition
  # for the date and the popularity. A new or a popular article that is not related must never go
  # past the floor because of that addition.
  def floor_for(scored)
    return MIN_SCORE if scored.size < 2

    values = scored.map { |row| row[:relevance] }
    mean = values.sum / values.size
    variance = values.sum { |value| (value - mean)**2 } / values.size

    [ mean + (FLOOR_SIGMAS * Math.sqrt(variance)), MIN_SCORE ].max
  end

  # ⚠️ MIN_SCORE is exclusive, and the floor from the standard deviation is not. A candidate at
  # exactly MIN_SCORE is not related, and it must go. But each candidate is at the floor from the
  # standard deviation when every score is equal, and to remove all of them would be incorrect.
  def above_floor?(row, floor)
    row[:relevance] > MIN_SCORE && row[:relevance] >= floor
  end

  # Maximal marginal relevance. It selects a candidate that is relevant to the query and that is
  # also different from each candidate that it selected before.
  #
  # ⚠️ This is what makes the section go wider. The nearest four articles are frequently
  # near-copies of each other, and the reader then gets one direction and not four.
  # @param scored [Array<Hash>] The candidates that went past the floor.
  def select_by_mmr(scored, count)
    return scored.first(count) if scored.size <= 1

    remaining = scored.sort_by { |row| -row[:score] }
    selected = [ remaining.shift ]

    while selected.size < count && remaining.any?
      best = remaining.max_by do |entry|
        nearest = selected.map { |other| ArticleSimilarity.similarity(entry[:vector], other[:vector]) }.max
        (MMR_LAMBDA * entry[:score]) - ((1.0 - MMR_LAMBDA) * nearest)
      end

      selected << best
      remaining.delete(best)
    end

    selected
  end

  # The small addition for each candidate, from its date and from the visitors of all time. It is
  # never more than PRIOR_WEIGHT.
  #
  # ⚠️ The code adds this and does not multiply by it. A similarity after the mean subtraction can
  # be negative, and a multiplier above 1 would make such a score smaller.
  # @return [Hash{String=>Float}] id => the addition.
  def priors(pool)
    visitors = all_time_visitors
    largest = visitors.values.max.to_f
    now = Time.now

    pool.each_with_object(Hash.new(0.0)) do |article, acc|
      id = article.sys&.id
      next if id.blank?

      popularity = largest.positive? ? Math.log(1 + visitors[article.path].to_i) / Math.log(1 + largest) : 0.0
      acc[id] = PRIOR_WEIGHT * ((popularity + freshness(article, now)) / 2.0)
    end
  end

  # @return [Float] 1.0 for an article of today, and one half at AGE_HALF_LIFE_DAYS.
  def freshness(article, now)
    published = DateTime.parse(article.published_at).to_time
    age_days = (now - published) / 86_400.0
    return 0.0 if age_days.negative?

    0.5**(age_days / AGE_HALF_LIFE_DAYS)
  rescue Date::Error, TypeError
    0.0
  end

  # ⚠️ The pageviews widget already caches this query body. Thus this costs no more Plausible
  # calls. A failure gives an empty hash, and the addition is then 0 for each article.
  def all_time_visitors
    totals = @plausible.totals_by_path(date_range: "all") || {}
    totals.each_with_object(Hash.new(0)) { |(path, values), acc| acc[path] = values[:visitors].to_i }
  end

  # A failure here gives an empty tree, thus the taxonomy part of the score becomes 0 and the
  # vector similarity alone puts the articles in order.
  def taxonomy_tree
    rescue_with({}, context: "#{self.class.name} taxonomy") { @taxonomy.tree } || {}
  end

  # @return [Hash] { id => vector or nil } for each id, in one request.
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
end
