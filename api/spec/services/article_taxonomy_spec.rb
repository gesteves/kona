require "rails_helper"

RSpec.describe ArticleTaxonomy do
  subject(:taxonomy) { described_class.new(articles: corpus, tree: tree) }

  def article(id:, concept_ids: [])
    DeepOstruct.wrap(concept_ids: concept_ids, sys: { id: id })
  end

  # Triathlon > Full distance > Kona, and Triathlon > Half distance. "Race Reports" is a topic on
  # each article.
  let(:tree) do
    {
      "triathlon" => { broader: [], scheme: "sports" },
      "full-distance" => { broader: [ "triathlon" ], scheme: "sports" },
      "kona" => { broader: [ "full-distance" ], scheme: "sports" },
      "half-distance" => { broader: [ "triathlon" ], scheme: "sports" },
      "race-reports" => { broader: [], scheme: "topics" }
    }
  end

  let(:corpus) do
    [
      article(id: "kona1", concept_ids: %w[kona race-reports]),
      article(id: "kona2", concept_ids: %w[kona race-reports]),
      article(id: "half", concept_ids: %w[half-distance race-reports]),
      article(id: "plain", concept_ids: %w[race-reports])
    ]
  end

  describe "#overlap" do
    it "gives the most to two articles that share a rare concept" do
      expect(taxonomy.overlap("kona1", "kona2")).to be > taxonomy.overlap("kona1", "half")
    end

    # ⚠️ This is why the code weights each concept by its IDF. "Race Reports" is on each article
    # here, thus it gives no information. A plain Jaccard would make these two look related.
    it "gives nothing to two articles that share only a concept that each article has" do
      expect(taxonomy.overlap("plain", "kona1")).to eq(0.0)
    end

    it "gives a small value to two articles that share an ancestor only" do
      value = taxonomy.overlap("kona1", "half")

      expect(value).to be > 0.0
      expect(value).to be < taxonomy.overlap("kona1", "kona2")
    end

    it "gives 0.0 for an id that it does not know" do
      expect(taxonomy.overlap("kona1", "unknown")).to eq(0.0)
    end
  end

  describe "#race_concept_id" do
    it "gives the deepest sports concept at the race level" do
      expect(taxonomy.race_concept_id(corpus.first)).to eq("kona")
    end

    # Triathlon > Half distance is a chain of 2, thus it is a distance and not a race.
    it "gives nil when no sports concept is deep enough" do
      expect(taxonomy.race_concept_id(corpus[2])).to be_nil
    end

    it "gives nil for an article with no sports concept" do
      expect(taxonomy.race_concept_id(corpus.last)).to be_nil
    end
  end

  it "does not raise with an empty tree" do
    plain = described_class.new(articles: corpus, tree: {})

    expect(plain.race_concept_id(corpus.first)).to be_nil
    expect(plain.overlap("kona1", "kona2")).to be_a(Float)
  end
end
