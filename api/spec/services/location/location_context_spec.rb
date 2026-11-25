require "rails_helper"

RSpec.describe LocationContext do
  subject(:context) { described_class.new(43.48, -110.76) }

  let(:gmaps) { instance_double(GoogleMaps, geocoded: geocoded, time_zone_id: "America/Denver") }

  before { allow(GoogleMaps).to receive(:new).with(43.48, -110.76).and_return(gmaps) }

  def component(types, long_name)
    { types: types, long_name: long_name }
  end

  context "a US location" do
    let(:geocoded) do
      {
        formatted_address: "1600 Somewhere, Denver, CO",
        address_components: [
          component(%w[locality political], "Denver"),
          component(%w[administrative_area_level_2 political], "Denver County"),
          component(%w[administrative_area_level_1 political], "Colorado"),
          component(%w[country political], "United States")
        ]
      }
    end

    it "resolves the city, state, country, timezone, label, and location string" do
      expect(context.city).to eq("Denver")
      expect(context.state).to eq("Colorado")
      expect(context.country).to eq("United States")
      expect(context.timezone).to eq("America/Denver")
      expect(context.label).to eq("Denver, Colorado")
      expect(context.location).to eq("Denver, Colorado, United States")
      expect(context.lat).to eq(43.48)
      expect(context.lon).to eq(-110.76)
    end
  end

  context "in Teton County, Wyoming" do
    let(:geocoded) do
      {
        formatted_address: "A precise cabin, WY",
        address_components: [
          component(%w[locality political], "Wilson"),
          component(%w[administrative_area_level_2 political], "Teton County"),
          component(%w[administrative_area_level_1 political], "Wyoming"),
          component(%w[country political], "United States")
        ]
      }
    end

    it "obfuscates the precise city to Jackson Hole (profile + location string + label)" do
      expect(context.city).to eq("Jackson Hole")
      expect(context.location).to eq("Jackson Hole, Wyoming, United States")
      expect(context.label).to eq("Jackson Hole, Wyoming")
    end
  end

  context "without a locality" do
    let(:geocoded) do
      {
        formatted_address: "Some township",
        address_components: [
          component(%w[administrative_area_level_3 political], "Some Township"),
          component(%w[administrative_area_level_1 political], "California"),
          component(%w[country political], "United States")
        ]
      }
    end

    it "falls back through the broader admin levels for the city" do
      expect(context.city).to eq("Some Township")
    end
  end

  context "when geocoding and the timezone lookup fail" do
    let(:geocoded) { nil }

    before { allow(gmaps).to receive(:time_zone_id).and_return(nil) }

    it "leaves the fields nil, uses the default label, and does not force a timezone" do
      expect(context.city).to be_nil
      expect(context.state).to be_nil
      expect(context.country).to be_nil
      expect(context.timezone).to be_nil
      expect(context.label).to eq("Current location")
      expect(context.location).to eq("Current location")
    end
  end

  context "when geocoding fails but a formatted address is available" do
    let(:geocoded) { { formatted_address: "Middle of the ocean" } }

    it "uses the formatted address as the label" do
      expect(context.label).to eq("Middle of the ocean")
    end
  end
end
