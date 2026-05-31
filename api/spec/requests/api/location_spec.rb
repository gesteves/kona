require "rails_helper"

RSpec.describe "Api::Location", type: :request do
  context "with a current location" do
    before do
      allow(Location).to receive(:new).and_return(double(latitude: 43.66, longitude: -110.72))
      allow(GoogleMaps).to receive(:new).and_return(double(location: {
        geocoded: { address_components: [{ long_name: "Wyoming", short_name: "WY", types: ["administrative_area_level_1"] }] },
        time_zone: { time_zone_id: "America/Denver" },
        elevation: 1968.79
      }))
    end

    it "returns the geocoded location as JSON, uncached" do
      get "/api/location"

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(response.headers["Netlify-CDN-Cache-Control"]).to be_nil

      body = JSON.parse(response.body)
      expect(body.dig("time_zone", "time_zone_id")).to eq("America/Denver")
      expect(body["elevation"]).to eq(1968.79)
      expect(body["geocoded"]["address_components"]).to be_an(Array)
    end
  end

  context "when no location is available" do
    before { allow(Location).to receive(:new).and_return(double(latitude: nil, longitude: nil)) }

    it "returns a null payload" do
      get "/api/location"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq("geocoded" => nil, "time_zone" => nil, "elevation" => nil)
    end
  end
end
