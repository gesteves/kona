# Puts the articles of the "You May Also Like" section in order. It makes a BM25 index of the text
# of each article, gives each candidate a score, and lets MMR select the final list.
#
# The score of one candidate has three parts:
#   * relevance = (LEXICAL_WEIGHT · BM25 similarity + taxonomy weight · concept overlap), with a
#                 demotion when the candidate reports the same race as the query article.
#   * evidence  = relevance + LINK_BONUS when the author linked the two entries.
#   * prior     = an addition for the popularity of the candidate and for a publish date near the
#                 date of the query article.
#
# ⚠️ The prior is large enough to select inside a group of candidates with a near-equal relevance.
# For a race report, the candidates are twenty other race reports and their relevance forms a flat
# band, and the words that they share are noise. In that band, the popularity and the season are
# what predict a click. `rake related:evaluate` measures this against the real navigation.
class RelatedArticles < ApplicationService
  include ArticleRanking # candidates, shared with TrendingArticles

  # The weight of the BM25 similarity. The concept overlap gets the rest.
  #
  # ⚠️ The taxonomy earns a large share here. A person assigned each concept, and it is the only
  # signal for a pair of articles that shares no words.
  LEXICAL_WEIGHT = ENV.fetch("RELATED_LEXICAL_WEIGHT", 0.65).to_f
  # The balance of MMR: 1.0 is relevance only, and 0.0 is diversity only.
  MMR_LAMBDA = ENV.fetch("RELATED_MMR_LAMBDA", 0.7).to_f
  # The addition for a link between the two entries, in either direction.
  LINK_BONUS = ENV.fetch("RELATED_LINK_BONUS", 0.15).to_f
  # The largest addition for the popularity of a candidate.
  POPULARITY_WEIGHT = ENV.fetch("RELATED_POPULARITY_WEIGHT", 0.1).to_f
  # The largest addition for a publish date near the date of the query article.
  SEASON_WEIGHT = ENV.fetch("RELATED_SEASON_WEIGHT", 0.1).to_f
  # The width of the season, in days. The addition is one half of SEASON_WEIGHT at 1.18 sigma.
  SEASON_SIGMA_DAYS = 120.0
  # The candidates that go into MMR. A larger pool gives MMR more to select from, and it costs one
  # similarity for each pair inside the pool.
  MMR_POOL = 24
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
  # @return [Hash, nil] { rows: }, or nil when the corpus or the text is absent.
  def explain(id, count: 4)
    pool = candidates
    published = @articles.list.reject(&:draft)
    return if pool.blank? || published.blank?

    article = published.find { |a| a.sys&.id == id }
    return if article.nil?

    context = build_context(published, pool, detailed: true)
    return unless context[:index].key?(id)

    scored = score_rows(article, pool, context)
    selected = select_by_mmr(mmr_pool(scored), count, context[:index]).map { |row| row[:id] }.to_set

    { rows: mmr_pool(scored, limit: nil).map { |row| row.merge(selected: selected.include?(row[:id])) } }
  end

  private

  # Everything that each query article reads: the lexical index, the taxonomy scorer, the links,
  # the popularity, the dates, and the race of each candidate. The code makes it one time for the
  # full corpus.
  # @param detailed [Boolean] True to also give the shared terms of each pair, for the report.
  def build_context(published, pool, detailed: false)
    ids = (published + pool).filter_map { |article| article.sys&.id }.uniq
    taxonomy = ArticleTaxonomy.new(articles: published, tree: taxonomy_tree)
    corpus = @articles.corpus.slice(*ids)

    {
      # ⚠️ The index reads the published entries alone. A draft in it would change the IDF of each
      # term and the mean document length, thus it would move a score that no person can explain.
      index: ArticleIndex.new(corpus),
      links: ArticleLinks.new(corpus, published.to_h { |a| [ a.sys&.id, a.path ] }),
      detailed: detailed,
      titles: published.each_with_object({}) { |a, acc| acc[a.sys&.id] = a.title },
      dates: published.each_with_object({}) { |a, acc| acc[a.sys&.id] = published_time(a) },
      taxonomy: taxonomy,
      # ⚠️ One time for each article, and not one time for each pair. This loop compares each
      # article against each other article.
      races: published.each_with_object({}) { |a, acc| acc[a.sys&.id] = taxonomy.race_concept_id(a) },
      popularity: popularity(pool)
    }
  end

  # Gives each candidate a score against one query article and lets MMR select the final list.
  # @return [Array<String>] The ids of the neighbors, the nearest first.
  def neighbors_for(article, pool, context, count)
    scored = score_rows(article, pool, context)

    select_by_mmr(mmr_pool(scored), count, context[:index]).map { |row| row[:id] }
  end

  # @return [Array<Hash>] The candidates by score, the best first, and the first `limit` of them.
  def mmr_pool(scored, limit: MMR_POOL)
    ranked = scored.sort_by { |row| -row[:score] }
    limit ? ranked.first(limit) : ranked
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
      link = context[:links].linked?(id, other_id)
      prior = context[:popularity][other_id].to_f + season(context[:dates][id], context[:dates][other_id])

      {
        id: other_id,
        title: context[:titles][other_id],
        lexical: lexical,
        overlap: overlap,
        link: link,
        relevance: relevance,
        prior: prior,
        score: relevance + (link ? LINK_BONUS : 0.0) + prior,
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

  # The addition for the popularity of each candidate, from the visitors of all time. It is never
  # more than POPULARITY_WEIGHT.
  #
  # ⚠️ The code adds this and does not multiply by it. A multiplier would give the largest lift to
  # the candidate that is already the most relevant, and almost none to the others. Thus it would
  # make the first position stronger and it would not select between two near-equal candidates,
  # which is the one purpose of this addition.
  # @return [Hash{String=>Float}] id => the addition.
  def popularity(pool)
    visitors = all_time_visitors
    largest = visitors.values.max.to_f
    return Hash.new(0.0) unless largest.positive?

    pool.each_with_object(Hash.new(0.0)) do |article, acc|
      id = article.sys&.id
      next if id.blank?

      acc[id] = POPULARITY_WEIGHT * Math.log(1 + visitors[article.path].to_i) / Math.log(1 + largest)
    end
  end

  # The addition for a candidate from the same season as the query article. A reader of a race
  # report goes to the other reports of that season.
  # @return [Float] SEASON_WEIGHT for the same day, and less as the two dates separate.
  def season(query_time, other_time)
    return 0.0 if query_time.nil? || other_time.nil?

    days = (query_time - other_time).abs / 86_400.0
    SEASON_WEIGHT * Math.exp(-((days / SEASON_SIGMA_DAYS)**2) / 2.0)
  end

  # @return [Time, nil] The publish time, or nil when the code cannot parse it.
  def published_time(article)
    DateTime.parse(article.published_at).to_time
  rescue Date::Error, TypeError
    nil
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
