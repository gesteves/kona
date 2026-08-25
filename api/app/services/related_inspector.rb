# The reports of `rake related:inspect` and `rake related:audit`.
#
# ⚠️ No A/B test can operate at the traffic of this site. Thus these two reports are the only
# method to know if a change to the ranking of RelatedArticles helped. `inspect_article` calls
# RelatedArticles#explain, thus the report can never describe a different ranking.
class RelatedInspector < ApplicationService
  # The audit reads a sample of the pairs and not each one, because the number of pairs grows with
  # the square of the corpus.
  SAMPLE_SIZE = 120
  # The number of cards that the section renders. The build takes this many from the list.
  SECTION_COUNT = 4

  def initialize(articles: Articles.new, related: RelatedArticles.new)
    @articles = articles
    @related = related
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
      floor: report[:floor],
      total: report[:rows].size,
      above_floor: report[:rows].count { |row| row[:above_floor] },
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

  private

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
