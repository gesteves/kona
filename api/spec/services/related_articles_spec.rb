require "rails_helper"

RSpec.describe RelatedArticles do
  subject(:service) { described_class.new(articles: articles, plausible: plausible, taxonomy: taxonomy) }

  let(:articles) { instance_double(Articles) }
  let(:plausible) { instance_double(Plausible, totals_by_path: nil) }
  let(:taxonomy) { instance_double(TaxonomyConcepts, tree: tree) }
  let(:tree) { {} }

  # Makes an article with the fields that Articles#list gives.
  def article(id:, slug:, published_at:, entry_type: "Article", draft: false, concept_ids: [])
    path = "/#{DateTime.parse(published_at).strftime('%Y/%m/%d')}/#{slug}/"
    DeepOstruct.wrap(
      title: slug.capitalize, slug: slug, summary: "A summary.", published_at: published_at,
      entry_type: entry_type, draft: draft, path: path, concept_ids: concept_ids,
      sys: { id: id, published_version: 1 }
    )
  end

  def vec_json(vector)
    { version: 1, vector: vector }.to_json
  end

  # The vectors give this order from the similarity to the query: near, then mid, then far. The
  # article itself, the draft, and the Short have the same vector as the query, thus their
  # similarity is 1. That shows that the code removes them for their id and their type, and not for
  # a low score.
  let(:store) do
    {
      "embeddings:article:q1" => vec_json([ 1.0, 0.0, 0.0 ]),
      "embeddings:article:near" => vec_json([ 0.9, 0.1, 0.0 ]),
      "embeddings:article:mid" => vec_json([ 0.8, 0.2, 0.0 ]),
      "embeddings:article:far" => vec_json([ 0.0, 1.0, 0.0 ]),
      "embeddings:article:draft" => vec_json([ 1.0, 0.0, 0.0 ]),
      "embeddings:article:short" => vec_json([ 1.0, 0.0, 0.0 ])
    }
  end

  let(:corpus) do
    [
      article(id: "q1", slug: "self", published_at: "2024-05-01T10:00:00Z"),
      article(id: "near", slug: "near", published_at: "2024-04-01T10:00:00Z"),
      article(id: "mid", slug: "mid", published_at: "2024-03-01T10:00:00Z"),
      article(id: "far", slug: "far", published_at: "2024-02-01T10:00:00Z"),
      article(id: "draft", slug: "draft", published_at: "2024-01-01T10:00:00Z", draft: true),
      article(id: "short", slug: "short", published_at: "2024-01-15T10:00:00Z", entry_type: "Short")
    ]
  end

  before do
    allow(articles).to receive(:list).and_return(corpus)
    allow($redis).to receive(:get) { |key| store[key] }
    allow($redis).to receive(:setex)
    allow($redis).to receive(:mget) { |*keys| keys.map { |key| store[key] } }
  end

  describe "#all" do
    it "puts the neighbors of each entry in order, the nearest first" do
      expect(service.all["q1"]).to eq(%w[near mid])
    end

    it "omits the query article itself, a draft, and a Short" do
      expect(service.all["q1"]).not_to include("q1", "draft", "short")
    end

    # ⚠️ A Short is a correct query article, because the section appears on its own page.
    # ArticleRanking#candidates keeps it out of each neighbor list.
    it "keys a Short, and never gives one as a neighbor" do
      result = service.all

      expect(result).to have_key("short")
      expect(result.values.flatten).not_to include("short")
    end

    it "omits a draft as a query article and as a neighbor" do
      result = service.all

      expect(result).not_to have_key("draft")
      expect(result.values.flatten).not_to include("draft")
    end

    it "omits an entry with no stored vector" do
      store.delete("embeddings:article:near")
      result = service.all

      expect(result).not_to have_key("near")
      expect(result.values.flatten).not_to include("near")
    end

    it "gives no more than `count` neighbors" do
      expect(service.all(count: 1)["q1"]).to eq(%w[near])
    end

    it "reads each vector in one round trip" do
      expect($redis).to receive(:mget).once.and_call_original

      service.all
    end

    # ⚠️ The key says "this entry has an embedding". Thus the coverage report of the web build can
    # tell a missing embedding from a floor that removed each candidate.
    it "keys an entry with a vector even when no candidate goes past the floor" do
      allow(articles).to receive(:list).and_return(corpus)
      stub_const("RelatedArticles::FLOOR_SIGMAS", 100.0)

      result = service.all

      expect(result).to have_key("q1")
      expect(result["q1"]).to eq([])
    end

    it "gives an empty hash and does not raise when the corpus is not available" do
      allow(articles).to receive(:list).and_return([])

      expect(service.all).to eq({})
    end
  end

  # ⚠️ The floor is what stops four unrelated cards below "You May Also Like". After the mean
  # subtraction a score at or below 0 means "not more alike than two articles of this corpus
  # usually are".
  describe "the floor" do
    let(:store) do
      {
        "embeddings:article:q1" => vec_json([ 1.0, 0.0, 0.0 ]),
        "embeddings:article:a" => vec_json([ 0.0, 1.0, 0.0 ]),
        "embeddings:article:b" => vec_json([ 0.0, 0.0, 1.0 ])
      }
    end

    let(:corpus) do
      [
        article(id: "q1", slug: "self", published_at: "2024-05-01T10:00:00Z"),
        article(id: "a", slug: "a", published_at: "2024-04-01T10:00:00Z"),
        article(id: "b", slug: "b", published_at: "2024-03-01T10:00:00Z")
      ]
    end

    it "gives an empty list when nothing is truly related" do
      expect(service.all["q1"]).to eq([])
    end
  end

  describe "the taxonomy" do
    let(:tree) do
      {
        "triathlon" => { broader: [], scheme: "sports" },
        "full-distance" => { broader: [ "triathlon" ], scheme: "sports" },
        "kona" => { broader: [ "full-distance" ], scheme: "sports" },
        "race-reports" => { broader: [], scheme: "topics" }
      }
    end

    let(:store) do
      {
        "embeddings:article:q1" => vec_json([ 1.0, 0.0, 0.0 ]),
        "embeddings:article:shared" => vec_json([ 0.2, 1.0, 0.0 ]),
        "embeddings:article:alone" => vec_json([ 0.2, 1.0, 0.0 ])
      }
    end

    let(:corpus) do
      [
        article(id: "q1", slug: "self", published_at: "2024-05-01T10:00:00Z",
                concept_ids: %w[kona race-reports]),
        article(id: "shared", slug: "shared", published_at: "2024-04-01T10:00:00Z",
                concept_ids: %w[kona race-reports]),
        article(id: "alone", slug: "alone", published_at: "2024-04-01T10:00:00Z",
                concept_ids: %w[race-reports])
      ]
    end

    # The two candidates have the same vector. Thus the concept overlap alone decides the order.
    it "puts the article that shares a rare concept above one that shares only a common concept" do
      expect(service.all["q1"].first).to eq("shared")
    end

    it "does not raise when the concept tree is not available" do
      allow(taxonomy).to receive(:tree).and_raise(StandardError, "down")

      expect { service.all }.not_to raise_error
    end
  end

  describe "#explain" do
    it "gives each part of the score of each candidate" do
      report = service.explain("q1")
      row = report[:rows].first

      expect(report[:floor]).to be_a(Float)
      expect(row).to include(:id, :title, :raw, :centered, :overlap, :relevance, :score, :above_floor, :selected)
      expect(row[:id]).to eq("near")
      expect(row[:selected]).to be(true)
    end

    it "gives nil for an entry with no stored vector" do
      expect(service.explain("unknown")).to be_nil
    end
  end

  # ⚠️ MMR is what makes the section go wider. The nearest four articles are frequently
  # near-copies of each other, thus the reader got one direction and not four.
  describe "the MMR diversity" do
    # The floor is off, thus this example measures MMR alone.
    before { stub_const("RelatedArticles::FLOOR_SIGMAS", -10.0) }

    let(:store) do
      {
        "embeddings:article:q1" => vec_json([ 1.0, 0.0, 0.0 ]),
        # Three near-copies of each other, and all three are close to the query.
        "embeddings:article:c1" => vec_json([ 0.98, 0.20, 0.0 ]),
        "embeddings:article:c2" => vec_json([ 0.97, 0.21, 0.0 ]),
        "embeddings:article:c3" => vec_json([ 0.96, 0.22, 0.0 ]),
        # A different direction, and only a little further from the query.
        "embeddings:article:other" => vec_json([ 0.95, 0.0, 0.30 ])
      }
    end

    let(:corpus) do
      %w[q1 c1 c2 c3 other].each_with_index.map do |id, index|
        article(id: id, slug: id, published_at: "2024-0#{index + 1}-01T10:00:00Z")
      end
    end

    it "selects a different article before a third near-copy" do
      expect(service.all(count: 2)["q1"]).to eq(%w[c1 other])
    end

    it "still puts the nearest article first" do
      expect(service.all(count: 4)["q1"].first).to eq("c1")
    end

    # This is the order with no diversity, and it is what MMR corrects above.
    it "gives three near-copies when the balance is relevance only" do
      stub_const("RelatedArticles::MMR_LAMBDA", 1.0)

      expect(service.all(count: 3)["q1"]).to eq(%w[c1 c2 c3])
    end
  end

  describe "the same-race demotion" do
    let(:tree) do
      {
        "triathlon" => { broader: [], scheme: "sports" },
        "full-distance" => { broader: [ "triathlon" ], scheme: "sports" },
        "kona" => { broader: [ "full-distance" ], scheme: "sports" },
        "roth" => { broader: [ "full-distance" ], scheme: "sports" }
      }
    end

    let(:store) do
      {
        "embeddings:article:q1" => vec_json([ 1.0, 0.0, 0.0 ]),
        "embeddings:article:same" => vec_json([ 0.9, 0.1, 0.0 ]),
        "embeddings:article:different" => vec_json([ 0.9, 0.1, 0.0 ])
      }
    end

    let(:corpus) do
      [
        article(id: "q1", slug: "self", published_at: "2024-05-01T10:00:00Z", concept_ids: %w[kona]),
        article(id: "same", slug: "same", published_at: "2024-04-01T10:00:00Z", concept_ids: %w[kona]),
        article(id: "different", slug: "different", published_at: "2024-04-01T10:00:00Z", concept_ids: %w[roth])
      ]
    end

    # The concept overlap is off, thus this example measures the demotion alone. The two
    # candidates have the same vector.
    it "lowers the score of a report of the same race" do
      stub_const("RelatedArticles::TAXONOMY_WEIGHT", 0.0)
      rows = service.explain("q1")[:rows].index_by { |row| row[:id] }

      expect(rows["same"][:relevance]).to be < rows["different"][:relevance]
    end

    # ⚠️ It is a demotion and never an exclusion. A Short renders the related section with no
    # "More Reports From This Race" section above it, thus the same race must stay available. The
    # demotion is also small on purpose: a shared rare concept is true relatedness, and it wins.
    it "keeps a report of the same race in the list" do
      expect(service.all["q1"]).to include("same")
    end
  end
end
