require "rails_helper"

RSpec.describe RelatedInspector do
  subject(:inspector) { described_class.new(articles: articles, related: related) }

  let(:articles) { instance_double(Articles) }
  let(:related) { instance_double(RelatedArticles) }

  def article(id:, slug:)
    DeepOstruct.wrap(
      title: slug.capitalize, slug: slug, published_at: "2024-05-01T10:00:00Z",
      entry_type: "Article", draft: false, path: "/2024/05/01/#{slug}/",
      sys: { id: id, published_version: 2 }
    )
  end

  let(:list) { [ article(id: "a1", slug: "one"), article(id: "a2", slug: "two") ] }

  let(:corpus) do
    {
      "a1" => { title: "One", summary: nil, intro: nil, body: "alpha bravo charlie" },
      "a2" => { title: "Two", summary: nil, intro: nil, body: "alpha bravo delta" }
    }
  end

  before do
    allow(articles).to receive(:list).and_return(list)
    allow(articles).to receive(:corpus).and_return(corpus)
    allow(related).to receive(:all).and_return("a1" => %w[a2], "a2" => %w[a1])
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

    it "says so for an entry that the index does not hold" do
      allow(related).to receive(:explain).with("a1").and_return(nil)

      expect(inspector.inspect_article("one")[:error]).to include("no text")
    end
  end

  describe "#audit" do
    # ⚠️ The index needs no external call, thus each published entry belongs in it. A gap here
    # means that the api could not read the corpus from Contentful.
    it "counts how much of the corpus the index holds" do
      report = inspector.audit

      expect(report[:total]).to eq(2)
      expect(report[:indexed]).to eq(2)
      expect(report[:coverage]).to eq(100.0)
    end

    it "counts the entries that got a list and the lists that are short" do
      report = inspector.audit

      expect(report[:keyed]).to eq(2)
      expect(report[:short]).to eq(2)
    end

    it "gives the spread of the similarity of a pair" do
      expect(inspector.audit[:spread]).to include(:mean, :sd)
    end

    it "reports an entry that the index does not hold" do
      allow(articles).to receive(:corpus).and_return(corpus.except("a2"))

      report = inspector.audit

      expect(report[:indexed]).to eq(1)
      expect(report[:coverage]).to eq(50.0)
    end

    it "does not raise for an empty corpus" do
      allow(articles).to receive(:list).and_return([])
      allow(articles).to receive(:corpus).and_return({})
      allow(related).to receive(:all).and_return({})

      expect { inspector.audit }.not_to raise_error
    end
  end
end
