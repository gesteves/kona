require "rails_helper"

RSpec.describe ArticleSimilarity do
  # Two vectors that point the same way but have different lengths. A dot product of the raw
  # vectors would be 8, and the similarity of their direction is 1.
  it "gives 1.0 for two vectors that point the same way" do
    prepared = described_class.prepare("a" => [ 2.0, 0.0 ], "b" => [ 4.0, 0.0 ])

    expect(described_class.similarity(prepared["a"], prepared["b"])).to be_within(1e-9).of(1.0)
  end

  it "gives 0.0 for two vectors at a right angle" do
    prepared = described_class.prepare("a" => [ 1.0, 0.0 ], "b" => [ 0.0, 1.0 ])

    expect(described_class.similarity(prepared["a"], prepared["b"])).to be_within(1e-9).of(0.0)
  end

  it "gives 0.0 when a vector is absent or the two lengths differ" do
    expect(described_class.similarity(nil, [ 1.0 ])).to eq(0.0)
    expect(described_class.similarity([ 1.0, 0.0 ], [ 1.0 ])).to eq(0.0)
  end

  it "keeps a nil in the output, thus a caller can see the entry with no vector" do
    expect(described_class.prepare("a" => [ 1.0, 0.0 ], "b" => nil)["b"]).to be_nil
  end

  # ⚠️ This is the change that makes the ranker operate. Each vector below points nearly the same
  # way, which is the corpus of one author and one domain. The raw similarities are all near 1, and
  # the order between them is near to noise. After the mean subtraction they separate.
  describe "the mean subtraction" do
    let(:vectors) do
      (0...12).each_with_object({}) do |i, acc|
        acc["a#{i}"] = [ 1.0, i * 0.01, 0.0 ]
      end
    end

    it "makes the spread of the similarities much larger" do
      raw = vectors.transform_values { |v| described_class.unit(v) }
      centered = described_class.prepare(vectors)

      expect(spread(centered)).to be > (spread(raw) * 10)
    end

    it "leaves a corpus below MIN_FOR_CENTERING unchanged, and only makes it a unit vector" do
      small = { "a" => [ 3.0, 4.0 ] }

      expect(described_class.prepare(small)["a"]).to eq([ 0.6, 0.8 ])
    end

    def spread(prepared)
      values = prepared.values.combination(2).map { |a, b| described_class.similarity(a, b) }
      mean = values.sum / values.size
      Math.sqrt(values.sum { |value| (value - mean)**2 } / values.size)
    end
  end
end
