# The reports of `rake related:inspect` and `rake related:audit`.
#
# ⚠️ No A/B test can operate at the traffic of this site. Thus these two reports are the only
# method to know if a change to the ranking of RelatedArticles helped. `inspect_article` calls
# RelatedArticles#explain, thus the report can never describe a different ranking.
class RelatedInspector < ApplicationService
  # The audit compares the spread of the similarity before and after the mean subtraction. It uses
  # a sample and not each pair, because the number of pairs grows with the square of the corpus.
  SAMPLE_SIZE = 120
  # Below this ratio of new spread against old spread, the mean subtraction did not separate the
  # scores enough, and the chunk method is the next step.
  GOOD_SPREAD_GAIN = 1.5

  def initialize(articles: Articles.new, related: RelatedArticles.new)
    @articles = articles
    @related = related
  end

  # @param slug [String] The slug of the query article.
  # @return [Hash] The report, or { error: } when the code cannot make one.
  def inspect_article(slug)
    article = @articles.list.reject(&:draft).find { |a| a.slug == slug }
    return { error: "No published entry has the slug #{slug.inspect}." } if article.nil?

    id = article.sys&.id
    report = @related.explain(id)
    return { error: "#{slug} has no stored embedding. Run rake embeddings:backfill." } if report.nil?

    {
      title: article.title,
      path: article.path,
      floor: report[:floor],
      total: report[:rows].size,
      above_floor: report[:rows].count { |row| row[:above_floor] },
      rows: report[:rows]
    }
  end

  # @return [Hash] The health of the corpus.
  def audit
    published = @articles.list.reject(&:draft)
    vectors = load_vectors(published)
    present = vectors.compact_blank

    raw = spread(present.values.map { |v| ArticleSimilarity.unit(v) })
    centered = spread(ArticleSimilarity.prepare(present).values)
    stale_ids = stale(published)

    {
      total: published.size,
      with_vector: present.size,
      coverage: published.empty? ? 0 : (100.0 * present.size / published.size).round(1),
      stale: stale_ids.size,
      stale_ids: stale_ids,
      raw: raw,
      centered: centered,
      verdict: verdict(raw, centered)
    }
  end

  private

  # The mean and the standard deviation of the similarity of a sample of pairs.
  # @return [Hash] { mean:, sd: }.
  def spread(vectors)
    return { mean: 0.0, sd: 0.0 } if vectors.size < 2

    sample = vectors.first(SAMPLE_SIZE)
    values = []
    sample.each_with_index do |a, i|
      sample[(i + 1)..].each { |b| values << ArticleSimilarity.similarity(a, b) }
    end
    return { mean: 0.0, sd: 0.0 } if values.empty?

    mean = values.sum / values.size
    variance = values.sum { |value| (value - mean)**2 } / values.size

    { mean: mean, sd: Math.sqrt(variance) }
  end

  # Says if the mean subtraction separated the scores enough.
  def verdict(raw, centered)
    return "Too few vectors to judge the spread." if centered[:sd].zero?

    gain = raw[:sd].zero? ? Float::INFINITY : centered[:sd] / raw[:sd]
    if gain >= GOOD_SPREAD_GAIN
      format("The mean subtraction made the spread %.1f times larger. The scores separate.", gain)
    else
      format(
        "The mean subtraction made the spread %.1f times larger only. The scores still group " \
        "together, thus read the chunk method in the plan.", gain
      )
    end
  end

  # @return [Hash{String=>Array<Float>,nil}] The stored vector of each entry.
  def load_vectors(published)
    ids = published.filter_map { |article| article.sys&.id }
    return {} if ids.empty?

    raw = $redis.mget(*ids.map { |id| ArticleEmbeddingJob.redis_key(id) })
    ids.zip(raw).to_h { |id, json| [ id, parse_payload(json)&.dig("vector") ] }
  end

  # The entries whose stored embedding is older than the entry itself. Contentful never sends a
  # webhook again, thus this is the only method to find one.
  # @return [Array<String>]
  def stale(published)
    ids = published.filter_map { |article| article.sys&.id }
    return [] if ids.empty?

    versions = ids.zip($redis.mget(*ids.map { |id| ArticleEmbeddingJob.redis_key(id) }))
                  .to_h { |id, json| [ id, parse_payload(json)&.dig("version") ] }

    published.filter_map do |article|
      id = article.sys&.id
      current = article.sys&.published_version
      stored = versions[id]
      next if id.blank? || current.blank? || stored.blank?

      id if stored.to_i < current.to_i
    end
  end

  def parse_payload(json)
    return if json.blank?
    JSON.parse(json)
  rescue JSON::ParserError
    nil
  end
end
