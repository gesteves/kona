require "rails_helper"

RSpec.describe RelatedInspector do
  subject(:inspector) { described_class.new(articles: articles, related: related) }

  let(:articles) { instance_double(Articles) }
  let(:related) { instance_double(RelatedArticles) }

  def article(id:, slug:, version: 2)
    DeepOstruct.wrap(
      title: slug.capitalize, slug: slug, published_at: "2024-05-01T10:00:00Z",
      entry_type: "Article", draft: false, path: "/2024/05/01/#{slug}/",
      sys: { id: id, published_version: version }
    )
  end

  let(:corpus) { [ article(id: "a1", slug: "one"), article(id: "a2", slug: "two") ] }

  def vec_json(vector, version: 2)
    { version: version, vector: vector }.to_json
  end

  let(:store) do
    {
      "embeddings:article:a1" => vec_json([ 1.0, 0.0 ]),
      "embeddings:article:a2" => vec_json([ 0.0, 1.0 ])
    }
  end

  before do
    allow(articles).to receive(:list).and_return(corpus)
    allow($redis).to receive(:mget) { |*keys| keys.map { |key| store[key] } }
  end

  describe "#inspect_article" do
    it "gives the report of the ranking of that article" do
      allow(related).to receive(:explain).with("a1").and_return(
        floor: 0.1,
        rows: [ { id: "a2", title: "Two", score: 0.4, above_floor: true, selected: true } ]
      )

      report = inspector.inspect_article("one")

      expect(report[:title]).to eq("One")
      expect(report[:total]).to eq(1)
      expect(report[:above_floor]).to eq(1)
    end

    it "says so for a slug that no entry has" do
      expect(inspector.inspect_article("nothing")[:error]).to include("nothing")
    end

    it "says so for an entry with no stored embedding" do
      allow(related).to receive(:explain).with("a1").and_return(nil)

      expect(inspector.inspect_article("one")[:error]).to include("embeddings:backfill")
    end
  end

  describe "#audit" do
    it "counts the coverage of the embeddings" do
      report = inspector.audit

      expect(report[:total]).to eq(2)
      expect(report[:with_vector]).to eq(2)
      expect(report[:coverage]).to eq(100.0)
    end

    it "gives the spread of the similarity before and after the mean subtraction" do
      report = inspector.audit

      expect(report[:raw]).to include(:mean, :sd)
      expect(report[:centered]).to include(:mean, :sd)
      expect(report[:verdict]).to be_a(String)
    end

    # ⚠️ Contentful never sends a webhook again. Thus this is the only method to find an entry
    # whose embedding missed one.
    it "names each entry whose stored embedding is older than the entry" do
      store["embeddings:article:a2"] = vec_json([ 0.0, 1.0 ], version: 1)

      report = inspector.audit

      expect(report[:stale_ids]).to eq([ "a2" ])
    end

    it "names no entry when each embedding is current" do
      expect(inspector.audit[:stale_ids]).to eq([])
    end

    it "does not raise for an empty corpus" do
      allow(articles).to receive(:list).and_return([])

      expect { inspector.audit }.not_to raise_error
    end
  end
end
