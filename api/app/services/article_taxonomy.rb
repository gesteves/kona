# The taxonomy part of the score of RelatedArticles. It gives each pair of articles an overlap
# value from their Contentful concepts, and it finds the race concept of an article.
class ArticleTaxonomy
  # The weight of an ancestor against a concept that the entry names. Thus "Half distance" and
  # "Full distance" match weakly through their shared "Triathlon" parent.
  ANCESTOR_WEIGHT = 0.3
  # A sports concept needs a chain of this length to be a race. The chain is discipline, then
  # distance, then the race. web/lib/helpers/article_helpers.rb uses the same number.
  RACE_CHAIN_DEPTH = 3
  # The scheme that holds the race concepts.
  SPORTS_SCHEME = "sports".freeze

  # @param articles [Array<OpenStruct>] The corpus. Its concepts give each document frequency.
  # @param tree [Hash] The output of TaxonomyConcepts#tree.
  def initialize(articles:, tree: {})
    @tree = tree || {}
    @ancestors = {}
    @depths = {}
    # An article with no id cannot be a candidate, and two such articles would share one key.
    @weights = articles.each_with_object({}) do |article, acc|
      id = article.sys&.id
      acc[id] = expand(article) if id.present?
    end
    @idf = inverse_document_frequencies(articles)
  end

  # The overlap of two articles, as a weighted Jaccard over their concepts.
  #
  # ⚠️ The IDF weight is the point of this method, and not a refinement. "Race Reports" is on most
  # articles and gives almost no information, and "Ironman Canada" is very specific. A plain
  # Jaccard would let the common concepts control the result, and each article would then look
  # related to each other article.
  #
  # @return [Float] A value from 0.0 to 1.0.
  def overlap(a_id, b_id)
    a = @weights[a_id]
    b = @weights[b_id]
    return 0.0 if a.blank? || b.blank?

    # Walk each hash one time and make no union: this runs for each pair of the corpus.
    intersection = union = 0.0
    a.each do |concept, a_weight|
      weight = @idf[concept] || 0.0
      next if weight.zero?

      b_weight = b[concept] || 0.0
      intersection += [ a_weight, b_weight ].min * weight
      union += [ a_weight, b_weight ].max * weight
    end
    b.each do |concept, b_weight|
      next if a.key?(concept)

      union += b_weight * (@idf[concept] || 0.0)
    end

    union.zero? ? 0.0 : intersection / union
  end

  # The race concept of an article: its deepest sports concept at the race level or below it.
  # @return [String, nil] The concept id, or nil when the article names no race.
  #
  # ⚠️ The depth is the length of the longest chain to a root, and not the number of ancestors.
  # A concept with two parents has more ancestors than its chain is long, and a count would call
  # a distance a race.
  def race_concept_id(article)
    Array(article.concept_ids)
      .select { |id| @tree.dig(id, :scheme) == SPORTS_SCHEME }
      .map { |id| [ id, depth_of(id) ] }
      .select { |_id, depth| depth >= RACE_CHAIN_DEPTH }
      .max_by { |_id, depth| depth }
      &.first
  end

  private

  # @param id [String] A concept id.
  # @param seen [Set] The ids on the current chain, against a cycle.
  # @return [Integer] The length of the longest chain from the concept to a root, the concept
  #   included.
  def depth_of(id, seen = Set.new)
    return @depths[id] if @depths.key?(id)
    return 1 if seen.include?(id)

    parents = Array(@tree.dig(id.to_s, :broader))
    depth = 1 + parents.map { |parent| depth_of(parent, seen | [ id ]) }.max.to_i
    @depths[id] = depth
  end

  # The ancestors of a concept, one time for each concept and not for each article.
  # @return [Array<String>]
  def ancestors_of(id)
    @ancestors[id] ||= TaxonomyConcepts.ancestor_ids(id, @tree)
  end

  # The concepts of one article and their weights: 1.0 for a concept that the entry names, and
  # ANCESTOR_WEIGHT for an ancestor of one.
  # @return [Hash{String=>Float}]
  def expand(article)
    direct = Array(article.concept_ids).compact
    weights = direct.each_with_object({}) { |id, acc| acc[id] = 1.0 }

    direct.each do |id|
      ancestors_of(id).each do |ancestor|
        weights[ancestor] = [ weights[ancestor] || 0.0, ANCESTOR_WEIGHT ].max
      end
    end

    weights
  end

  # log(N / df) for each concept. A concept on each article gets a weight of 0, thus it cannot
  # make two articles look related.
  # @return [Hash{String=>Float}]
  def inverse_document_frequencies(articles)
    total = articles.size
    return {} if total.zero?

    frequencies = Hash.new(0)
    @weights.each_value { |weights| weights.each_key { |id| frequencies[id] += 1 } }
    frequencies.transform_values { |count| Math.log(total.to_f / count) }
  end
end
