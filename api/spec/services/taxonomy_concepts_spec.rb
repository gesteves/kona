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
end
