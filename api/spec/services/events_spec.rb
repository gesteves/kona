require "rails_helper"

RSpec.describe Events do
  subject(:service) { described_class.new }

  let(:client) { instance_double(ContentfulClient) }
  let(:item) { { title: "Ironman Canada", trackingUrl: "https://track.test/1", date: "2026-08-30", coordinates: { lat: 50.1, lon: -119.4 }, sys: { id: "e1" } } }

  before do
    allow(ContentfulClient).to receive(:new).with("Events").and_return(client)
    allow($redis).to receive(:get).and_return(nil)
    allow($redis).to receive(:setex)
  end

  describe "#all" do
    it "reads every page, strictly, and gives each event with snake_case keys and dot access" do
      allow(client).to receive(:paginate).with(Events::QUERY, collection: :events, strict: true).and_return([ item ])

      events = service.all

      expect(events.length).to eq(1)
      expect(events.first.tracking_url).to eq("https://track.test/1")
      expect(events.first.coordinates.lat).to eq(50.1)
    end

    it "gives no events, and does not raise, when Contentful fails" do
      allow(client).to receive(:paginate).and_raise(ApplicationService::HttpError.new(500, "", "contentful"))

      expect(service.all).to eq([])
    end
  end

  describe "#find" do
    it "reads one event by its id" do
      allow(client).to receive(:items).with(Events::FIND_QUERY, { id: "e1" }, collection: :events).and_return([ item ])

      expect(service.find("e1").title).to eq("Ironman Canada")
    end

    it "gives nil for a blank id and asks Contentful nothing" do
      allow(client).to receive(:items)

      expect(service.find(nil)).to be_nil
      expect(client).not_to have_received(:items)
    end
  end
end
