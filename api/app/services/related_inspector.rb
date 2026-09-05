# The reports of `rake related:inspect`, `rake related:audit`, and `rake related:evaluate`.
#
# ⚠️ No A/B test can operate at the traffic of this site. Thus these reports are the only method
# to know if a change to the ranking of RelatedArticles helped. `inspect_article` calls
# RelatedArticles#explain, thus the report can never describe a different ranking. `evaluate`
# measures the lists against the real navigation of the readers.
class RelatedInspector < ApplicationService
  # The audit reads a sample of the pairs and not each one, because the number of pairs grows with
  # the square of the corpus.
  SAMPLE_SIZE = 120
  # The number of cards that the section renders. The build takes this many from the list.
  SECTION_COUNT = 4
  # The number of neighbors that the build gets for each entry, and the largest number of cards
  # that it removes: the reports of the same race, and the two adjacent entries.
  FETCH_COUNT = 10
  # A page with fewer transitions than this does not go into the metric.
  MIN_TRANSITIONS = 5

  def initialize(articles: Articles.new, related: RelatedArticles.new, plausible: Plausible.new, taxonomy: TaxonomyConcepts.new)
    @articles = articles
    @related = related
    @plausible = plausible
    @taxonomy = taxonomy
  end

  # @param slug [String] The slug of the query article.
  # @return [Hash] The report, or { error: } when the code cannot make one.
  def inspect_article(slug)
    article = @articles.list.reject(&:draft).find { |a| a.slug == slug }
    return { error: "No published entry has the slug #{slug.inspect}." } if article.nil?

    report = @related.explain(article.sys&.id)
    return { error: "#{slug} has no text, thus the index holds nothing for it." } if report.nil?

    {
      title: article.title,
      path: article.path,
      total: report[:rows].size,
      rows: report[:rows]
    }
  end

  # The health of the corpus: how much of it the index holds, how many entries get a full section,
  # and how far the similarities separate.
  # @return [Hash]
  def audit
    published = @articles.list.reject(&:draft)
    ids = published.filter_map { |article| article.sys&.id }
    index = ArticleIndex.new(@articles.corpus.slice(*ids))
    indexed = ids.count { |id| index.key?(id) }
    neighbors = @related.all(count: SECTION_COUNT) || {}

    {
      total: published.size,
      indexed: indexed,
      coverage: published.empty? ? 0.0 : (100.0 * indexed / published.size).round(1),
      keyed: neighbors.size,
      short: neighbors.count { |_id, list| list.size < SECTION_COUNT },
      spread: spread(index, ids)
    }
  end

  # The recall of the section against the real navigation: of the readers who went from an entry
  # to another entry in one visit, the share that went to a card of the section. It makes the
  # 4-card list as the build does: it removes the reports of the same race, the two adjacent
  # entries, and the entry itself.
  #
  # ⚠️ The transitions come from the modules of the past, thus the metric prefers what those
  # modules showed. A transition to a Short is not counted: a Short is never a card.
  # @param count [Integer] The number of cards of the section.
  # @return [Hash] { pages:, hits:, total:, recall: }. The recall is nil with no transitions.
  def evaluate(count: SECTION_COUNT)
    published = @articles.list.reject(&:draft)
    ids_by_path = published.each_with_object({}) { |a, acc| acc[a.path] = a.sys&.id if a.path.present? }
    types = published.to_h { |a| [ a.sys&.id, a.entry_type ] }
    races = race_groups(published)
    adjacent = adjacent_ids(published)
    neighbors = @related.all(count: FETCH_COUNT) || {}
    transitions = @plausible.covisit_visitors(date_range: "all") || {}

    hits = total = pages = 0
    transitions.each do |from_path, destinations|
      from = ids_by_path[from_path]
      next if from.nil?

      removed = races.fetch(from, Set.new) | adjacent.fetch(from, Set.new) | Set[from]
      truth = destinations.each_with_object({}) do |(to_path, visitors), acc|
        to = ids_by_path[to_path]
        next if to.nil? || removed.include?(to) || types[to] == "Short"

        acc[to] = acc.fetch(to, 0) + visitors.to_i
      end
      next if truth.values.sum < MIN_TRANSITIONS

      list = Array(neighbors[from]).reject { |id| removed.include?(id) }.first(count)
      pages += 1
      truth.each do |to, visitors|
        total += visitors
        hits += visitors if list.include?(to)
      end
    end

    { pages: pages, hits: hits, total: total, recall: total.positive? ? (hits.to_f / total).round(3) : nil }
  end

  private

  # The reports of the same race as each Article, which the build renders above the section.
  # @return [Hash{String=>Set<String>}]
  def race_groups(published)
    taxonomy = ArticleTaxonomy.new(articles: published, tree: taxonomy_tree)
    articles = published.select { |a| a.entry_type == "Article" }
    by_race = articles.group_by { |a| taxonomy.race_concept_id(a) }
    by_race.delete(nil)

    articles.each_with_object({}) do |a, acc|
      race = taxonomy.race_concept_id(a)
      next if race.nil?

      acc[a.sys&.id] = by_race[race].filter_map { |b| b.sys&.id }.to_set - [ a.sys&.id ]
    end
  end

  # The two adjacent entries in time of each entry, which the read-next section renders.
  # @return [Hash{String=>Set<String>}]
  def adjacent_ids(published)
    sequence = published.sort_by { |a| -published_time(a).to_i }.filter_map { |a| a.sys&.id }
    sequence.each_with_index.to_h do |id, index|
      newer = index.positive? ? sequence[index - 1] : nil
      [ id, [ newer, sequence[index + 1] ].compact.to_set ]
    end
  end

  def published_time(article)
    DateTime.parse(article.published_at).to_time
  rescue Date::Error, TypeError
    Time.at(0)
  end

  def taxonomy_tree
    rescue_with({}, context: "#{self.class.name} taxonomy") { @taxonomy.tree } || {}
  end

  # The mean and the standard deviation of the similarity of a sample of pairs. A larger standard
  # deviation means that the scores separate, thus the order carries more than noise.
  # @return [Hash] { mean:, sd: }.
  def spread(index, ids)
    sample = ids.first(SAMPLE_SIZE)
    return { mean: 0.0, sd: 0.0 } if sample.size < 2

    values = []
    sample.each_with_index do |a, i|
      sample[(i + 1)..].each { |b| values << index.similarity(a, b) }
    end
    return { mean: 0.0, sd: 0.0 } if values.empty?

    mean = values.sum / values.size
    variance = values.sum { |value| (value - mean)**2 } / values.size

    { mean: mean, sd: Math.sqrt(variance) }
  end
end
