# The lexical index of RelatedArticles: a BM25 vector for each article, and the similarity of two
# articles.
#
# ⚠️ BM25 replaces a neural embedding here, on purpose. This corpus is approximately 60 entries by
# one author in one domain. An embedding of such a corpus puts most of its magnitude into the one
# direction that each entry shares, thus the scores group into a narrow band and the order is near
# to noise. The IDF of BM25 removes that shared vocabulary by design, and it needs no correction.
#
# ⚠️ A person can read the words that two articles share, and that is necessary here. The traffic of
# this site is too small for an A/B test. Thus a person must read the order and judge it, and
# `terms_in_common` is what makes that possible.
class ArticleIndex
  include MarkdownHelper # markdown_to_plain_text, to remove the Markdown syntax before the tokens

  # How many times the words of each field go into the token list of a document. A title is very
  # informative here, for example "Race Report: 2025 Ironman 70.3 Boise".
  FIELD_WEIGHTS = { title: 3, summary: 2, intro: 1, body: 1 }.freeze
  # How much a repeat of one term adds to its weight.
  K1 = 1.2
  # ⚠️ The length normalization is necessary and not a refinement. The median Article is
  # approximately 18,000 characters and the median Short is approximately 1,000. At 0, each long
  # article would win against each Short at every query.
  B = 0.75
  # A word of three letters or more, which starts and ends with a letter.
  #
  # ⚠️ There is no stop word list, on purpose. The IDF gives a term that most of the corpus holds a
  # weight near zero, thus a list would remove almost nothing and it would add a file to maintain.
  TOKEN_PATTERN = /[a-z][a-z'-]+[a-z]/
  # How many shared terms `terms_in_common` gives.
  TOP_TERMS = 3

  # @param documents [Hash{String=>Hash}] Contentful id => { title:, summary:, intro:, body: }.
  #   Each value holds Markdown or plain text, and an absent field is permitted.
  def initialize(documents)
    @vectors = build(documents || {})
  end

  # The similarity of two articles.
  # @return [Float] 0.0 to 1.0, and 0.0 when the index does not hold one of the two ids.
  def similarity(a_id, b_id)
    a = @vectors[a_id]
    b = @vectors[b_id]
    return 0.0 if a.blank? || b.blank?

    # Walk the smaller vector, thus the cost follows the shorter of the two articles.
    a, b = b, a if a.size > b.size
    a.sum { |term, weight| weight * b.fetch(term, 0.0) }
  end

  # The terms that give the similarity of two articles most of its value. `rake related:inspect`
  # prints them, and they are the reason to prefer this index to a vector.
  # @return [Array<String>] The terms, the largest first.
  def terms_in_common(a_id, b_id, limit: TOP_TERMS)
    a = @vectors[a_id]
    b = @vectors[b_id]
    return [] if a.blank? || b.blank?

    a.filter_map { |term, weight| [ term, weight * b[term] ] if b.key?(term) }
     .max_by(limit) { |_term, weight| weight }
     .map(&:first)
  end

  # @return [Boolean] True when the index holds a vector for that id.
  def key?(id)
    @vectors[id].present?
  end

  private

  # Makes a BM25 vector of unit length for each document.
  # @return [Hash{String=>Hash{String=>Float}}]
  def build(documents)
    terms = documents.transform_values { |fields| tokenize(fields) }
    lengths = terms.transform_values(&:size)
    average = average_length(lengths)
    idf = inverse_document_frequency(terms)

    terms.each_with_object({}) do |(id, list), acc|
      acc[id] = vector(list, lengths[id], average, idf)
    end
  end

  # The token list of one document. The words of each field repeat by the weight of that field.
  def tokenize(fields)
    fields = fields || {}
    FIELD_WEIGHTS.flat_map do |field, weight|
      words = words_in(fields[field])
      weight > 1 ? words * weight : words
    end
  end

  # @param text [String, nil] Markdown or plain text.
  # @return [Array<String>] Its words, in lower case.
  def words_in(text)
    plain = markdown_to_plain_text(text)
    return [] if plain.blank?

    plain.downcase.scan(TOKEN_PATTERN)
  end

  # The inverse document frequency of each term, in the BM25 form.
  #
  # ⚠️ This is what makes the ranker operate on a corpus of one author. "triathlon" and "race"
  # are in most of this corpus and they get a weight near zero, thus they cannot decide an order.
  def inverse_document_frequency(terms)
    total = terms.size
    frequency = Hash.new(0)
    terms.each_value { |list| list.uniq.each { |term| frequency[term] += 1 } }

    frequency.transform_values do |count|
      Math.log(1 + ((total - count + 0.5) / (count + 0.5)))
    end
  end

  # @return [Float] The mean token count of the corpus, and 1.0 when it is empty.
  def average_length(lengths)
    return 1.0 if lengths.empty?

    average = lengths.values.sum / lengths.size.to_f
    average.positive? ? average : 1.0
  end

  # The BM25 weight of each term of one document, at unit length. Thus a similarity is a dot
  # product, and the code does not calculate a norm at each pair.
  def vector(list, length, average, idf)
    weights = list.tally.each_with_object({}) do |(term, count), acc|
      denominator = count + (K1 * (1 - B + (B * length / average)))
      acc[term] = idf[term] * count * (K1 + 1) / denominator
    end

    unit(weights)
  end

  # @return [Hash{String=>Float}] The weights at length 1, or the weights when their norm is zero.
  def unit(weights)
    norm = Math.sqrt(weights.sum { |_term, weight| weight * weight })
    return weights if norm.zero?

    weights.transform_values { |weight| weight / norm }
  end
end
