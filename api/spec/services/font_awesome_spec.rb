require "rails_helper"

RSpec.describe FontAwesome do
  subject(:service) { described_class.new }

  let(:cache_key) { "font-awesome:icon:#{FontAwesome::DEFAULT_VERSION}:classic:solid:eye" }
  let(:svg_markup) { '<svg viewBox="0 0 1 1"><path/></svg>' }
  let(:graphql_client) { double("GraphQL client") }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FONT_AWESOME_VERSION").and_return(nil)

    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)

    allow(FontAwesomeClient).to receive(:client).and_return(graphql_client)
    allow(FontAwesomeClient).to receive(:icons_query).and_return(:icons_query)
  end

  def stub_api_results(results)
    search = results.map { |r| double(to_h: r) }
    allow(graphql_client).to receive(:query).and_return(double(data: double(search: search)))
  end

  describe "#svg" do
    it "returns the cached SVG without hitting the API" do
      allow($redis).to receive(:get).with(cache_key).and_return(svg_markup)

      expect(service.svg("classic", "solid", "eye")).to eq(svg_markup)
      expect(FontAwesomeClient).not_to have_received(:client)
    end

    it "fetches, caches, and returns the SVG on a cache miss" do
      stub_api_results([{ "id" => "eye", "svgs" => [{ "familyStyle" => { "family" => "classic", "style" => "solid" }, "html" => svg_markup }] }])

      expect(service.svg("classic", "solid", "eye")).to eq(svg_markup)
      expect($redis).to have_received(:setex).with(cache_key, FontAwesome::CACHE_TTL, svg_markup)
    end

    it "negatively caches a definitive miss so an unknown icon id doesn't hit the API per render" do
      stub_api_results([])

      expect(service.svg("classic", "solid", "eye")).to be_nil
      expect($redis).to have_received(:setex).with(cache_key, FontAwesome::MISS_CACHE_TTL, "")
    end

    it "treats the cached-miss sentinel as nil without hitting the API" do
      allow($redis).to receive(:get).with(cache_key).and_return("")

      expect(service.svg("classic", "solid", "eye")).to be_nil
      expect(FontAwesomeClient).not_to have_received(:client)
    end

    it "does not cache anything on a transient API failure" do
      allow(graphql_client).to receive(:query).and_return(double(data: nil))

      expect(service.svg("classic", "solid", "eye")).to be_nil
      expect($redis).not_to have_received(:setex)
    end
  end
end
