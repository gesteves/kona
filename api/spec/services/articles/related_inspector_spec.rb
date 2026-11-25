require "rails_helper"

RSpec.describe RelatedInspector do
  subject(:inspector) { described_class.new(articles: articles, related: related, plausible: plausible, taxonomy: taxonomy) }

  let(:articles) { instance_double(Articles) }
  let(:related) { instance_double(RelatedArticles) }
  let(:plausible) { instance_double(Plausible, covisit_visitors: nil) }
  let(:taxonomy) { instance_double(TaxonomyConcepts, tree: {}) }

  def article(id:, slug:, published_at: "2024-05-01T10:00:00Z", entry_type: "Article")
    path = "/#{DateTime.parse(published_at).strftime('%Y/%m/%d')}/#{slug}/"
    DeepOstruct.wrap(
      title: slug.capitalize, slug: slug, published_at: published_at,
      entry_type: entry_type, draft: false, path: path, concept_ids: [],
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
        rows: [ { id: "a2", title: "Two", score: 0.4, link: false, prior: 0.1, selected: true } ]
      )

      report = inspector.inspect_article("one")

      expect(report[:title]).to eq("One")
      expect(report[:total]).to eq(1)
      expect(report[:rows].first[:selected]).to be(true)
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

  # ⚠️ The metric makes the list as the build does: it removes the adjacent entries and the entry
  # itself, and it does not count a transition to an entry that can never be a card.
  describe "#evaluate" do
    let(:list) do
      [
        article(id: "a1", slug: "one", published_at: "2024-05-01T10:00:00Z"),
        article(id: "a2", slug: "two", published_at: "2024-04-01T10:00:00Z"),
        article(id: "a3", slug: "three", published_at: "2024-03-01T10:00:00Z"),
        article(id: "a4", slug: "four", published_at: "2024-02-01T10:00:00Z"),
        article(id: "s1", slug: "short", published_at: "2024-01-01T10:00:00Z", entry_type: "Short")
      ]
    end

    before do
      allow(related).to receive(:all).with(count: RelatedInspector::FETCH_COUNT).and_return("a1" => %w[a3 a4])
    end

    it "gives the share of the real transitions that go to a card of the section" do
      allow(plausible).to receive(:covisit_visitors).and_return(
        "/2024/05/01/one/" => { "/2024/03/01/three/" => 4, "/2024/02/01/four/" => 2 }
      )

      report = inspector.evaluate(count: 1)

      expect(report).to include(pages: 1, hits: 4, total: 6, recall: 0.667)
    end

    it "does not count a transition to an adjacent entry or to a Short" do
      allow(plausible).to receive(:covisit_visitors).and_return(
        "/2024/05/01/one/" => { "/2024/04/01/two/" => 10, "/2024/01/01/short/" => 10, "/2024/03/01/three/" => 5 }
      )

      expect(inspector.evaluate).to include(hits: 5, total: 5, recall: 1.0)
    end

    it "skips a page with too few transitions" do
      allow(plausible).to receive(:covisit_visitors).and_return(
        "/2024/05/01/one/" => { "/2024/03/01/three/" => RelatedInspector::MIN_TRANSITIONS - 1 }
      )

      expect(inspector.evaluate).to include(pages: 0, recall: nil)
    end

    it "gives a nil recall when Plausible is not available" do
      expect(inspector.evaluate[:recall]).to be_nil
    end
  end
end
