# Puts the articles of the "You May Also Like" section in order. It makes a BM25 index of the text
# of each article, gives each candidate a score, and returns the nearest ones.
#
# The score of one candidate has two parts:
#   * relevance = (LEXICAL_WEIGHT · BM25 similarity + taxonomy weight · concept overlap), with a
#                 demotion when the candidate reports the same race as the query article.
#   * score     = relevance + a small addition for a recent article and for one that people read.
#
# A floor over the **relevance** marks each candidate that is truly related. MMR then selects the
# final list from those candidates first. ⚠️ The floor selects which candidates to prefer, and it
# never makes the list short: the section renders a two-column grid, thus it must always be full.
class RelatedArticles < ApplicationService
  include ArticleRanking # candidates, shared with TrendingArticles

  # The weight of the BM25 similarity. The concept overlap gets the rest.
  #
  # ⚠️ The taxonomy earns a large share here. A person assigned each concept, and it is the only
  # signal for a pair of articles that shares no words.
  LEXICAL_WEIGHT = ENV.fetch("RELATED_LEXICAL_WEIGHT", 0.65).to_f
  # The balance of MMR: 1.0 is relevance only, and 0.0 is diversity only.
  MMR_LAMBDA = ENV.fetch("RELATED_MMR_LAMBDA", 0.7).to_f
  # The floor, in standard deviations above the mean relevance of that query.
  FLOOR_SIGMAS = ENV.fetch("RELATED_FLOOR_SIGMAS", 0.5).to_f
  # The absolute part of the floor. Two articles of this corpus that share no rare word and no
  # concept score near zero, thus a relevance below this value means "not truly related".
  #
  # ⚠️ This value must stay above zero. A BM25 similarity and a concept overlap are both never
  # negative, thus a floor at zero would mark each candidate as related. Read `rake related:inspect`
  # after a change to LEXICAL_WEIGHT, because that weight moves this distribution.
  MIN_SCORE = 0.02
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
  # build. This reads the articles one time, and not one time for each article: the index is made
  # one time and the rest is arithmetic.
  #
  # ⚠️ No cache holds this. The build calls it one time, immediately after a publish. That is the
  # one moment when a list from ten minutes ago would be wrong, because it would omit the entry
  # that started the build.
  #
  # ⚠️ There is a key for each published entry, and not only for each candidate. A Short is a
  # correct query article, because the section appears on its own page, but a Short can never be a
  # neighbor.
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
        next if id.blank? || !context[:index].key?(id)

        acc[id] = neighbors_for(article, pool, context, count)
      end
    end
  end

  # The full score of each candidate against one article, for `rake related:inspect`. It uses the
  # same methods as `all`, thus the report can never describe a different ranking.
  # @param id [String] The Contentful id of the query article.
  # @param count [Integer] The number of neighbors that the section shows.
  # @return [Hash, nil] { floor:, rows: }, or nil when the corpus or the text is absent.
  def explain(id, count: 4)
    pool = candidates
    published = @articles.list.reject(&:draft)
    return if pool.blank? || published.blank?

    article = published.find { |a| a.sys&.id == id }
    return if article.nil?

    context = build_context(published, pool, detailed: true)
    return unless context[:index].key?(id)

    scored = score_rows(article, pool, context)
    floor = floor_for(scored)
    selected = select_by_mmr(mmr_pool(scored, count, floor: floor), count, context[:index]).map { |row| row[:id] }.to_set

    rows = scored.sort_by { |row| -row[:score] }.map do |row|
      row.merge(above_floor: above_floor?(row, floor), selected: selected.include?(row[:id]))
    end

    { floor: floor, rows: rows }
  end

  private

  # Everything that each query article reads: the lexical index, the taxonomy scorer, the
  # popularity, and the race of each candidate. The code makes it one time for the full corpus.
  # @param detailed [Boolean] True to also give the shared terms of each pair, for the report.
  def build_context(published, pool, detailed: false)
    ids = (published + pool).filter_map { |article| article.sys&.id }.uniq
    taxonomy = ArticleTaxonomy.new(articles: published, tree: taxonomy_tree)

    {
      # ⚠️ The index reads the published entries alone. A draft in it would change the IDF of each
      # term and the mean document length, thus it would move a score that no person can explain.
      index: ArticleIndex.new(@articles.corpus.slice(*ids)),
      detailed: detailed,
      titles: published.each_with_object({}) { |a, acc| acc[a.sys&.id] = a.title },
      taxonomy: taxonomy,
      # ⚠️ One time for each article, and not one time for each pair. This loop compares each
      # article against each other article.
      races: published.each_with_object({}) { |a, acc| acc[a.sys&.id] = taxonomy.race_concept_id(a) },
      priors: priors(pool)
    }
  end

  # Gives each candidate a score against one query article and lets MMR select the final list.
  # @return [Array<String>] The ids of the neighbors, the nearest first.
  def neighbors_for(article, pool, context, count)
    scored = score_rows(article, pool, context)

    select_by_mmr(mmr_pool(scored, count), count, context[:index]).map { |row| row[:id] }
  end

  # The candidates that go into MMR: each one above the floor, and then the best of the others when
  # too few go past it.
  #
  # ⚠️ The floor selects which candidates to PREFER, and it never makes the section short. The
  # section renders a two-column grid, thus a list of three leaves a hole. An article whose
  # candidates are all below the floor still gets a full list, and the best of a weak group is at
  # its start.
  # @return [Array<Hash>] The pool, the best first.
  def mmr_pool(scored, count, floor: nil)
    ranked = scored.sort_by { |row| -row[:score] }
    floor ||= floor_for(scored)
    above, below = ranked.partition { |row| above_floor?(row, floor) }

    preferred = above.first(MMR_POOL)
    preferred + below.first([ count - preferred.size, 0 ].max)
  end

  # The score of each candidate against one query article.
  # @return [Array<Hash>] One row for each candidate.
  def score_rows(article, pool, context)
    id = article.sys&.id
    index = context[:index]
    query_race = context[:races][id]

    pool.filter_map do |candidate|
      other_id = candidate.sys&.id
      # A candidate with no text carries no signal, thus it is not a neighbor.
      next if other_id.blank? || other_id == id || !index.key?(other_id)

      lexical = index.similarity(id, other_id)
      overlap = context[:taxonomy].overlap(id, other_id)
      penalty = same_race_penalty(other_id, query_race, context)
      relevance = ((LEXICAL_WEIGHT * lexical) + ((1.0 - LEXICAL_WEIGHT) * overlap)) * penalty

      {
        id: other_id,
        title: context[:titles][other_id],
        lexical: lexical,
        overlap: overlap,
        relevance: relevance,
        score: relevance + context[:priors][other_id].to_f,
        terms: context[:detailed] ? index.terms_in_common(id, other_id) : []
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
  # MIN_SCORE. Each candidate below it is not truly related, and `mmr_pool` prefers the others.
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
  # @param scored [Array<Hash>] The pool, from `mmr_pool`.
  # @param index [ArticleIndex] The source of the similarity of two candidates.
  def select_by_mmr(scored, count, index)
    return scored.first(count) if scored.size <= 1

    remaining = scored.sort_by { |row| -row[:score] }
    selected = [ remaining.shift ]

    while selected.size < count && remaining.any?
      best = remaining.max_by do |entry|
        nearest = selected.map { |other| index.similarity(entry[:id], other[:id]) }.max
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
  # ⚠️ The code adds this and does not multiply by it. A multiplier would give the largest lift to
  # the candidate that is already the most relevant, and almost none to the others. Thus it would
  # make the first position stronger and it would not select between two near-equal candidates,
  # which is the one purpose of this addition.
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

  # A failure here gives an empty tree, thus the taxonomy part of the score becomes 0 and the BM25
  # similarity alone puts the articles in order.
  def taxonomy_tree
    rescue_with({}, context: "#{self.class.name} taxonomy") { @taxonomy.tree } || {}
  end
end
