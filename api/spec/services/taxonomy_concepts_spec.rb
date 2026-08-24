require "rails_helper"

RSpec.describe TaxonomyConcepts do
  subject(:service) { described_class.new }

  before do
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("CONTENTFUL_SPACE").and_return("space")
    allow(ENV).to receive(:[]).with("CONTENTFUL_TOKEN").and_return("token")
  end

  it "maps concept ids to their localized prefLabel" do
    allow(service).to receive(:get_json).and_return(
      items: [
        { sys: { id: "triathlon" }, prefLabel: { "en-US": "Triathlon" } },
        { sys: { id: "ironman-703" }, prefLabel: { "en-US": "Ironman 70.3" } }
      ],
      pages: {}
    )
    expect(service.names).to eq("triathlon" => "Triathlon", "ironman-703" => "Ironman 70.3")
  end

  it "skips concepts missing an id or label" do
    allow(service).to receive(:get_json).and_return(
      items: [ { sys: { id: "x" } }, { prefLabel: { "en-US": "Y" } } ], pages: {}
    )
    expect(service.names).to eq({})
  end

  it "follows cursor pages" do
    page1 = { items: [ { sys: { id: "a" }, prefLabel: { "en-US": "A" } } ], pages: { next: "https://cdn.contentful.com/next" } }
    page2 = { items: [ { sys: { id: "b" }, prefLabel: { "en-US": "B" } } ], pages: {} }
    allow(service).to receive(:get_json).and_return(page1, page2)
    expect(service.names).to eq("a" => "A", "b" => "B")
  end

  it "returns an empty map when the fetch fails (so callers fall back to legacy tags)" do
    allow(service).to receive(:get_json).and_return(nil)
    expect(service.names).to eq({})
  end

  it "no-ops without Contentful credentials" do
    allow(ENV).to receive(:[]).with("CONTENTFUL_SPACE").and_return(nil)
    expect(service).not_to receive(:get_json)
    expect(service.names).to eq({})
  end

  describe ".ancestor_ids" do
    let(:tree) do
      {
        "triathlon" => { broader: [], scheme: "sports" },
        "full-distance" => { broader: [ "triathlon" ], scheme: "sports" },
        "kona" => { broader: [ "full-distance" ], scheme: "sports" }
      }
    end

    it "gives each ancestor, from the parent upward" do
      expect(described_class.ancestor_ids("kona", tree)).to eq(%w[full-distance triathlon])
    end

    # ⚠️ Array() gives the same object back for an array. Thus a queue with no copy changed the
    # tree of the caller, and the first article removed the ancestors for each one after it.
    it "does not change the tree that the caller gave" do
      described_class.ancestor_ids("kona", tree)

      expect(tree.dig("kona", :broader)).to eq([ "full-distance" ])
      expect(described_class.ancestor_ids("kona", tree)).to eq(%w[full-distance triathlon])
    end

    it "stops at a cycle in the data" do
      cyclic = { "a" => { broader: [ "b" ] }, "b" => { broader: [ "a" ] } }

      expect(described_class.ancestor_ids("a", cyclic)).to eq(%w[b a])
    end

    it "gives an empty list for an id that it does not know" do
      expect(described_class.ancestor_ids("unknown", tree)).to eq([])
    end
  end
end
