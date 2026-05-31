require "rails_helper"

RSpec.describe TimeZoneResolver do
  describe ".call" do
    it "returns the geocoded timezone for valid coordinates" do
      allow(GoogleMaps).to receive(:new).with(43.48, -110.76)
        .and_return(instance_double(GoogleMaps, time_zone_id: "America/Denver"))

      expect(described_class.call(43.48, -110.76)).to eq("America/Denver")
    end

    it "falls back to the default when coordinates are blank (without geocoding)" do
      expect(GoogleMaps).not_to receive(:new)
      expect(described_class.call(nil, nil)).to eq(described_class.default)
    end

    it "falls back to the default when geocoding yields no timezone" do
      allow(GoogleMaps).to receive(:new).and_return(instance_double(GoogleMaps, time_zone_id: nil))
      expect(described_class.call(1.0, 2.0)).to eq(described_class.default)
    end
  end

  describe ".default" do
    it "prefers the TIME_ZONE env var" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("TIME_ZONE", described_class::DEFAULT_TIME_ZONE).and_return("Europe/Paris")
      expect(described_class.default).to eq("Europe/Paris")
    end

    it "falls back to America/Denver" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("TIME_ZONE", "America/Denver").and_return("America/Denver")
      expect(described_class.default).to eq("America/Denver")
    end
  end
end
