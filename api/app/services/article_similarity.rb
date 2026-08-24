# The vector arithmetic of RelatedArticles: the mean subtraction, the unit length, and the
# similarity of two vectors.
#
# ⚠️ The code makes each vector a unit vector one time, thus a similarity is a dot product and not
# a cosine. The cosine method calculated the norm of both vectors at each pair. The ranker compares
# each article against each other article, thus it calculated the norm of the same vector some
# hundreds of times.
module ArticleSimilarity
  module_function

  # Below this number of vectors the mean has no meaning, thus the code does not subtract it.
  MIN_FOR_CENTERING = 10

  # Subtracts the mean vector, then makes each vector a unit vector.
  #
  # ⚠️ The mean subtraction is what makes this ranker operate. This corpus has one author, one
  # domain, and one genre. Thus each vector holds a large shared component, and the similarities
  # group into a narrow band where the order is near to noise. The subtraction removes that shared
  # direction, and the scores then separate.
  #
  # @param vectors [Hash{String=>Array<Float>,nil}] The raw vectors by id.
  # @return [Hash{String=>Array<Float>,nil}] The prepared vectors by id.
  def prepare(vectors)
    present = vectors.values.compact
    return vectors.transform_values { |v| v && unit(v) } if present.size < MIN_FOR_CENTERING

    mean = mean_vector(present)
    vectors.transform_values { |v| v && unit(subtract(v, mean)) }
  end

  # The similarity of two prepared vectors.
  # @return [Float] The dot product, or 0.0 when a vector is absent or the lengths differ.
  def similarity(a, b)
    return 0.0 if a.blank? || b.blank? || a.size != b.size

    total = 0.0
    a.each_index { |i| total += a[i] * b[i] }
    total
  end

  # @param vectors [Array<Array<Float>>] The vectors, each one of the same length.
  # @return [Array<Float>] Their mean.
  def mean_vector(vectors)
    size = vectors.first.size
    sums = Array.new(size, 0.0)
    vectors.each do |vector|
      next if vector.size != size
      vector.each_index { |i| sums[i] += vector[i] }
    end
    sums.map { |sum| sum / vectors.size }
  end

  # @return [Array<Float>] a - b, or a when the two lengths differ.
  def subtract(a, b)
    return a if a.size != b.size
    a.each_with_index.map { |value, i| value - b[i] }
  end

  # @return [Array<Float>] The vector at length 1, or the vector itself when its norm is zero.
  def unit(vector)
    norm = Math.sqrt(vector.sum { |value| value * value })
    return vector if norm.zero?
    vector.map { |value| value / norm }
  end
end
